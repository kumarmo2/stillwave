"""Synthetic single-output layer-shell compositor for non-desktop lifecycle tests."""
import socket
import struct
import threading

_send_locks = {}


def u(*values):
    return struct.pack("=" + "I" * len(values), *values)


def string(value):
    data = value.encode() + b"\0"
    return u(len(data)) + data + b"\0" * (-len(data) % 4)


def event(conn, obj, opcode, payload=b""):
    with _send_locks.setdefault(conn, threading.Lock()):
        conn.sendall(u(obj, ((8 + len(payload)) << 16) | opcode) + payload)


class Compositor:
    def __init__(self, path, scale=1, outputs=1):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(path))
        self.socket.listen(4)
        self.socket.settimeout(0.1)
        self.stopped = False
        self.scale = scale
        self.active_outputs = set(range(outputs))
        self.registries = []
        self.callbacks_enabled = True
        self.failures = []
        self.hides = self.swaps = self.handshakes = self.connections = 0
        self.clients = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped:
            try:
                conn, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            thread = threading.Thread(target=self.handle, args=(conn,), daemon=True)
            self.clients.append(thread)
            thread.start()

    def handle(self, conn):
        try:
            with conn:
                self.connection(conn)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.failures.append(exc)

    def connection(self, conn):
        types = {1: "wl_display"}
        surfaces = {}
        layers = {}
        serial = 0
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
                    self.registries.append((conn, reg))
                    for name, interface, version in [(10, "wl_compositor", 4),
                                                      (20, "zwlr_layer_shell_v1", 4)] + [
                        (11 + index, "wl_output", 4) for index in sorted(self.active_outputs)]:
                        event(conn, reg, 0, u(name) + string(interface) + u(version))
                elif kind == "wl_display" and opcode == 0:
                    cb, = struct.unpack("=I", payload)
                    event(conn, cb, 0, u(1))
                    event(conn, 1, 1, u(cb))
                elif kind == "wl_registry" and opcode == 0:
                    global_id, length = struct.unpack("=II", payload[:8])
                    interface = payload[8:8 + length - 1].decode()
                    offset = 8 + (length + 3) // 4 * 4
                    _, new = struct.unpack("=II", payload[offset:offset + 8])
                    types[new] = interface
                    if interface == "wl_output":
                        event(conn, new, 0, u(0, 0, 0, 0, 0) + string("Test") + string("Offscreen") + u(0))
                        event(conn, new, 1, u(1, 64, 64, 60000))
                        scale = self.scale[min(global_id - 11, len(self.scale) - 1)] if isinstance(self.scale, list) else self.scale
                        event(conn, new, 3, u(scale))
                        event(conn, new, 4, string(f"TEST-{global_id - 10}"))
                        event(conn, new, 5, string("Offscreen test output"))
                        event(conn, new, 2)
                elif kind == "wl_compositor":
                    new, = struct.unpack("=I", payload)
                    types[new] = "wl_surface" if opcode == 0 else "wl_region"
                    if opcode == 0:
                        surfaces[new] = dict(layer=None, initial=True, null=False, configured=False, frames=[])
                elif kind == "zwlr_layer_shell_v1" and opcode == 0:
                    new, surface = struct.unpack("=II", payload[:8])
                    types[new] = "zwlr_layer_surface_v1"
                    layers[new] = surfaces[surface]
                    surfaces[surface]["layer"] = new
                elif kind == "zwlr_layer_surface_v1" and opcode == 6:
                    layers[obj]["configured"] = True
                elif kind == "wl_surface":
                    s = surfaces[obj]
                    if opcode == 1:
                        s["null"] = struct.unpack("=I", payload[:4])[0] == 0
                    elif opcode == 3:
                        cb, = struct.unpack("=I", payload)
                        s["frames"].append(cb)
                    elif opcode == 6:
                        if s["null"]:
                            self.hides += 1
                            s.update(initial=True, null=False, configured=False)
                            # Release canceled callbacks; no drawing occurs here.
                            for cb in s["frames"]:
                                event(conn, cb, 0, u(1))
                                event(conn, 1, 1, u(cb))
                            s["frames"] = []
                        elif s["initial"]:
                            self.handshakes += 1
                            serial += 1
                            event(conn, s["layer"], 0, u(serial, 64, 64))
                            s["initial"] = False
                        else:
                            assert s["configured"], "swap before configure acknowledgement"
                            self.swaps += 1
                            if self.callbacks_enabled:
                                for cb in s["frames"]:
                                    event(conn, cb, 0, u(1))
                                    event(conn, 1, 1, u(cb))
                                s["frames"] = []

    def remove_output(self, index):
        self.active_outputs.remove(index)
        for conn, reg in self.registries:
            try:
                event(conn, reg, 1, u(11 + index))
            except OSError:
                pass

    def add_output(self, index):
        self.active_outputs.add(index)
        for conn, reg in self.registries:
            try:
                event(conn, reg, 0, u(11 + index) + string("wl_output") + u(4))
            except OSError:
                pass

    def close(self):
        self.stopped = True
        self.socket.close()
        self.thread.join(5)
        assert not self.thread.is_alive()
        for thread in self.clients:
            thread.join(5)
            assert not thread.is_alive()
        assert not self.failures, self.failures


