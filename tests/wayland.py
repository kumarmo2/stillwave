#!/usr/bin/env python3
"""Minimal fake Wayland servers: output/protocol discovery without any desktop UI."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/wallpaper-zig").resolve()

def u(*values):
    return struct.pack("=" + "I" * len(values), *values)

def i(*values):
    return struct.pack("=" + "i" * len(values), *values)

def string(value):
    data = value.encode() + b"\0"
    return u(len(data)) + data + b"\0" * (-len(data) % 4)

def event(conn, obj, opcode, payload=b""):
    conn.sendall(u(obj, ((8 + len(payload)) << 16) | opcode) + payload)

outputs = [
    {"name": "synthetic-left", "width": 3440, "height": 1440, "scale": 1, "transform": 0, "x": -3440, "y": 215},
    {"name": "synthetic-portrait", "width": 1920, "height": 1080, "scale": 2, "transform": 1, "x": 0, "y": -777},
    {"name": "synthetic-hi-dpi", "width": 5120, "height": 2880, "scale": 3, "transform": 0, "x": 540, "y": 303},
]


def scenario(version, use_xdg, args, expected_code=0):
    with tempfile.TemporaryDirectory(prefix="wallpaper-wayland-test-") as tmp:
        path = str(Path(tmp) / "socket")
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(1)
        failures = []

        def serve():
            try:
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(10)
                    types = {1: "wl_display"}
                    output_ids = {}
                    buffer = b""
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            return
                        buffer += chunk
                        while len(buffer) >= 8:
                            obj, header = struct.unpack("=II", buffer[:8])
                            size, opcode = header >> 16, header & 0xffff
                            if len(buffer) < size:
                                break
                            payload, buffer = buffer[8:size], buffer[size:]
                            kind = types[obj]
                            if kind == "wl_display" and opcode == 1:
                                reg, = struct.unpack("=I", payload)
                                types[reg] = "wl_registry"
                                event(conn, reg, 0, u(10) + string("wl_compositor") + u(4))
                                for index in range(len(outputs)):
                                    event(conn, reg, 0, u(100 + index) + string("wl_output") + u(version))
                                if use_xdg:
                                    event(conn, reg, 0, u(20) + string("zxdg_output_manager_v1") + u(3))
                            elif kind == "wl_display" and opcode == 0:
                                callback, = struct.unpack("=I", payload)
                                event(conn, callback, 0, u(1234))
                                event(conn, 1, 1, u(callback))
                            elif kind == "wl_registry" and opcode == 0:
                                name, length = struct.unpack("=II", payload[:8])
                                interface = payload[8:8 + length - 1].decode()
                                offset = 8 + (length + 3) // 4 * 4
                                bound_version, new_id = struct.unpack("=II", payload[offset:offset + 8])
                                types[new_id] = interface
                                if interface == "wl_output":
                                    output_ids[new_id] = name - 100
                                    o = outputs[name - 100]
                                    event(conn, new_id, 0, i(o["x"], o["y"], 0, 0, 0) + string("Test") + string("Virtual") + i(o["transform"]))
                                    event(conn, new_id, 1, u(1) + i(o["width"], o["height"], 144000))
                                    if bound_version >= 2:
                                        event(conn, new_id, 3, i(o["scale"]))
                                    if bound_version >= 4:
                                        event(conn, new_id, 4, string(o["name"]))
                                        event(conn, new_id, 5, string("Synthetic " + o["name"]))
                                    if bound_version >= 2:
                                        event(conn, new_id, 2)
                            elif kind == "zxdg_output_manager_v1" and opcode == 1:
                                new_id, output_id = struct.unpack("=II", payload)
                                types[new_id] = "zxdg_output_v1"
                                o = outputs[output_ids[output_id]]
                                event(conn, new_id, 0, i(o["x"], o["y"]))
                                event(conn, new_id, 1, i(o["width"], o["height"]))
                                event(conn, new_id, 3, string(o["name"]))
                                event(conn, new_id, 4, string("Synthetic " + o["name"]))
                                if version >= 2:
                                    event(conn, output_id, 2)
                            # All other requests are destructor/release requests.
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                failures.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        result = subprocess.run([str(binary), *args], env=os.environ | {"WAYLAND_DISPLAY": path},
                                capture_output=True, text=True, timeout=10)
        thread.join(10)
        server.close()
        assert not thread.is_alive(), "fake server did not stop"
        assert not failures, failures
        assert result.returncode == expected_code, (result.returncode, result.stderr)
        return result

for version, xdg in [(4, False), (2, True), (1, True), (1, False)]:
    result = scenario(version, xdg, ["list-outputs", "--json"])
    info = json.loads(result.stdout)
    assert len(info) == 3
    for expected, actual in zip(outputs, info):
        assert actual["mode_width"] == expected["width"]
        assert actual["mode_height"] == expected["height"]
        assert actual["transform"] == expected["transform"]
        assert actual["integer_scale"] == (expected["scale"] if version >= 2 else 1)
        assert actual["name"] == (expected["name"] if version >= 4 or xdg else None)

# The server deliberately offers no layer-shell. run must fail before EGL/surfaces.
with tempfile.NamedTemporaryFile() as media:
    result = scenario(4, False, ["run", "--no-config", media.name], expected_code=2)
    assert "zwlr_layer_shell_v1" in result.stderr and not result.stdout
print("5 non-visual Wayland protocol checks passed (synthetic multi-output servers)")
