#!/usr/bin/env python3
"""Transactional set-video checks with real mpv/FFmpeg and offscreen Mesa.
Never connects to the user's compositor or modifies their configuration.
"""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
from wayland_fixture import Compositor

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/stillwave").resolve()
root = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="sw-replacement-") as tmp:
    base = Path(tmp)
    shim = base / "egl.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/headless-egl.c"), "-o", str(shim),
                    "-ldl", "-lwayland-client"], check=True)
    for color in ("red", "blue"):
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        f"color={color}:size=64x64:rate=10", "-t", "2", "-c:v", "mpeg4",
                        str(base / f"{color}.mp4")], check=True, timeout=20)
    (base / "bad.mp4").write_bytes(b"not a video")
    mesa = next(Path("/usr/share/glvnd/egl_vendor.d").glob("*mesa*.json"))
    env = os.environ | {"XDG_RUNTIME_DIR": tmp, "WAYLAND_DISPLAY": "wayland-test",
                        "XDG_CONFIG_HOME": str(base / "config"), "HOME": tmp,
                        "LD_PRELOAD": str(shim), "LIBGL_ALWAYS_SOFTWARE": "1", "DISPLAY": "",
                        "__EGL_VENDOR_LIBRARY_FILENAMES": str(mesa), "PROBE_TEST_READBACK": "1"}
    env.pop("WAYLAND_SOCKET", None)
    compositor = Compositor(base / "wayland-test", outputs=2)
    owner = None
    log_path = base / "owner.log"
    config_path = base / "custom" / "config.json"
    original = '{\n  "media" : "../red.mp4",\n  "scale": "fit", "outputs": [], "paused": true\n}\n'

    def text():
        return log_path.read_text()

    def wait(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate():
                return
            assert owner.poll() is None, text()
            assert not compositor.failures, compositor.failures
            time.sleep(.01)
        raise AssertionError("timeout\n" + text())

    def command(*args, status=0):
        deadline = time.monotonic() + 15
        while True:
            result = subprocess.run([str(binary), *map(str, args)], env=env, cwd=base,
                                    capture_output=True, text=True, timeout=45)
            if status == 0 and result.returncode != 0 and "cleanup in progress" in result.stderr and time.monotonic() < deadline:
                time.sleep(.05)
                continue
            break
        assert result.returncode == status, (args, result.stderr, text())
        assert not result.stdout
        assert owner.poll() is None, text()
        return result

    def start(backend, source=None, delay=False, wait_frames=True, paused=True, loop=True):
        global owner
        log = log_path.open("w")
        selection = ["--config", str(config_path)] if source is None else source
        owner = subprocess.Popen([str(binary), "run", *selection, "--backend", backend,
                                  "--hwdec", "no", "--profile-startup",
                                  "--paused" if paused else "--no-paused",
                                  *([] if loop else ["--no-loop"]), str(base / "red.mp4")],
                                 env=env | ({"STILLWAVE_TEST_OPEN_DELAY_MS": "600"} if delay else {}),
                                 stdout=subprocess.DEVNULL, stderr=log)
        log.close()
        if wait_frames:
            wait(lambda: text().count("first frame submitted") >= 2)
        else:
            wait(lambda: bool(list(base.glob("stillwave-*/control.sock"))))

    def quit():
        command("quit")
        assert owner.wait(10) == 0, text()

    def color_since(offset, color):
        pixels = re.findall(r"pixel=(\d+),(\d+),(\d+),(\d+) surface=(\d+)", text()[offset:])
        latest = {p[4]: p for p in pixels}
        channel = 0 if color == "red" else 2
        return len(latest) >= 2 and all(int(p[channel]) > 220 and int(p[2 - channel]) < 30 for p in latest.values())

    try:
        for backend in ("mpv", "ffmpeg"):
            config_path.parent.mkdir(exist_ok=True)
            config_path.write_text(original)
            start(backend)
            # Basic file validation and failed decoding preserve both old players
            # and the exact original config bytes.
            for path in ("missing.mp4", ".", "bad.mp4"):
                command("set-video", path, status=1)
                assert config_path.read_text() == original
            wait(lambda: "decoder resources released" in text() if backend == "ffmpeg" else True)
            time.sleep(.1)  # asynchronous failed-candidate cleanup
            offset = len(text())
            command("set-video", "blue.mp4")  # relative to sender, not runner
            wait(lambda: color_since(offset, "blue"))
            expected = original.replace('"../red.mp4"', json.dumps(str(base / "blue.mp4")))
            assert config_path.read_text() == expected
            assert not (base / "config" / "stillwave" / "config.json").exists()
            # Old failures must not leak into the new players; paused replacements
            # settle rather than submitting frames in a tight loop.
            time.sleep(.2)
            before = compositor.swaps
            time.sleep(.2)
            assert compositor.swaps == before
            # Exercise repeated allocation/teardown and require correct pixels
            # on BOTH outputs, not two submissions from only one output.
            for color in ("red", "blue", "red", "blue"):
                offset = len(text())
                command("set-video", f"{color}.mp4")
                wait(lambda: color_since(offset, color))
            command("hide")
            time.sleep(.15)
            before = compositor.swaps
            command("set-video", "red.mp4")
            assert compositor.swaps == before, "hidden validation presented a frame"
            assert json.loads(config_path.read_text())["media"] == str(base / "red.mp4")
            offset = len(text())
            command("show")
            wait(lambda: color_since(offset, "red"))
            quit()

            # --no-config explicitly forbids persistence, even with valid media.
            start(backend, ["--no-config"])
            result = command("set-video", "blue.mp4", status=1)
            assert "--no-config" in result.stderr
            quit()

            # Missing implicit config is created; hidden-before-initialization
            # still validates without mapping any wallpaper or requiring a player.
            default = base / "config" / "stillwave" / "config.json"
            default.unlink(missing_ok=True)
            start(backend, [], wait_frames=False)
            command("hide")
            time.sleep(.15)
            before = compositor.swaps
            command("set-video", "blue.mp4")
            assert compositor.swaps == before
            assert json.loads(default.read_text()) == {"media": str(base / "blue.mp4")}
            command("show")
            wait(lambda: color_since(0, "blue"))
            quit()
            default.unlink()

        # Delay FFmpeg opening to exercise pending transaction controls/conflicts.
        config_path.write_text(original)
        start("ffmpeg", delay=True)
        pending = subprocess.Popen([str(binary), "set-video", str(base / "blue.mp4")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.2)
        command("set-video", "red.mp4", status=1)
        command("hide", status=1)
        command("show", status=1)
        manual = original.replace('"fit"', '"fill"')
        config_path.write_text(manual)
        stdout, stderr = pending.communicate(timeout=15)
        assert pending.returncode == 1 and "ConfigChangedDuringReplacement" in stderr, stderr
        assert not stdout and config_path.read_text() == manual
        time.sleep(.8)
        # A save failure AFTER decoding keeps the paused old blue/red state.
        config_path.write_text(original)
        pending = subprocess.Popen([str(binary), "set-video", str(base / "blue.mp4")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.2)
        config_path.parent.chmod(0o500)
        try:
            stdout, stderr = pending.communicate(timeout=15)
            assert pending.returncode == 1 and "ConfigWriteFailed" in stderr, stderr
            assert config_path.read_text() == original
            assert owner.poll() is None
        finally:
            config_path.parent.chmod(0o700)
        time.sleep(.8)
        # Metadata-only manual edits are conflicts too, not silently undone.
        pending = subprocess.Popen([str(binary), "set-video", str(base / "blue.mp4")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.2)
        config_path.chmod(0o400)
        stdout, stderr = pending.communicate(timeout=15)
        assert pending.returncode == 1 and "ConfigChangedDuringReplacement" in stderr, stderr
        assert config_path.stat().st_mode & 0o777 == 0o400
        config_path.chmod(0o600)
        time.sleep(.8)
        # Removal during loading aborts, while newly connected outputs subsequently
        # use the committed video. Neither topology change kills the owner.
        pending = subprocess.Popen([str(binary), "set-video", str(base / "blue.mp4")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.2)
        compositor.remove_output(1)
        stdout, stderr = pending.communicate(timeout=15)
        assert pending.returncode == 1 and "OutputsChangedDuringReplacement" in stderr, stderr
        assert config_path.read_text() == original
        time.sleep(.8)
        compositor.add_output(2)
        wait(lambda: "[TEST-3] configured" in text())
        offset = len(text())
        command("set-video", "blue.mp4")
        wait(lambda: color_since(offset, "blue"))
        # Invalid config targets reject before disturbing current playback.
        config_path.unlink()
        config_path.mkdir()
        command("set-video", "blue.mp4", status=1)
        assert config_path.is_dir()
        config_path.rmdir()
        config_path.write_text(manual)
        # Malformed/oversized payloads cannot be silently truncated into a path.
        socket_path = next(base.glob("stillwave-*/control.sock"))
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as raw:
            raw.bind("")
            raw.settimeout(3)
            for payload in (b"v", b"vrelative.mp4", b"v/a\0b", b"v/" + b"x" * 5000):
                raw.sendto(payload, str(socket_path))
                assert raw.recv(512) == b"E"
        quit()

        # Candidates are held at frame zero until commit, including short,
        # unpaused nonlooping media on multiple outputs.
        short = base / "short.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        "color=blue:size=64x64:rate=10", "-t", "0.2", "-c:v", "mpeg4",
                        str(short)], check=True)
        for backend in ("mpv", "ffmpeg"):
            config_path.write_text(original)
            start(backend, paused=False, loop=False)
            offset = len(text())
            result = subprocess.run([str(binary), "set-video", str(short)], env=env,
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, (result.stderr, text())
            assert owner.wait(10) == 0, text()
            assert color_since(offset, "blue"), text()
            assert json.loads(config_path.read_text())["media"] == str(short)
    finally:
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait(10)
        compositor.close()

print("Video replacement checks passed (mpv + FFmpeg, multi-output, persistence, rollback, hidden; no desktop)")
