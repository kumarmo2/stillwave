#!/usr/bin/env python3
"""Non-desktop lifecycle integration: fake Wayland + real libmpv/Mesa OpenGL.
Requires cc, ffmpeg, Mesa surfaceless EGL/software GL, and development headers.
Never connects to the user's compositor or creates desktop wallpaper surfaces.
"""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/stillwave").resolve()
root = Path(__file__).resolve().parents[1]


from wayland_fixture import Compositor


with tempfile.TemporaryDirectory(prefix="sw-control-") as tmp:
    base = Path(tmp)
    shim = base / "egl.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/headless-egl.c"), "-o", str(shim),
                    "-ldl", "-lwayland-client"], check=True)
    media = base / "video.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=64x64:rate=10", "-t", "2", "-c:v", "mpeg4",
                    str(media)], check=True, timeout=20)
    compositor = Compositor(base / "wayland-test")
    mesa = next(Path("/usr/share/glvnd/egl_vendor.d").glob("*mesa*.json"), None)
    assert mesa is not None, "Mesa EGL vendor JSON is required for offscreen tests"
    env = os.environ | {"XDG_RUNTIME_DIR": tmp, "WAYLAND_DISPLAY": "wayland-test",
                        "XDG_CONFIG_HOME": str(base / "config"), "HOME": tmp,
                        "LD_PRELOAD": str(shim), "LIBGL_ALWAYS_SOFTWARE": "1", "DISPLAY": "",
                        "__EGL_VENDOR_LIBRARY_FILENAMES": str(mesa)}
    env.pop("WAYLAND_SOCKET", None)
    owner = None
    log_path = base / "owner.log"

    def command(name, status=0, extra_env=None, extra_args=()):
        result = subprocess.run([str(binary), name, *extra_args], env=env | (extra_env or {}),
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == status, (name, result.returncode, result.stderr)
        assert not result.stdout
        return result

    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate():
                return
            assert owner.poll() is None, log_path.read_text()
            assert not compositor.failures, compositor.failures
            time.sleep(0.01)
        raise AssertionError("timed out\n" + log_path.read_text())

    def start(paused=False, wait_frame=True, loop=True, suppress_restart=False, delay_end=False):
        global owner
        log = log_path.open("w")
        owner = subprocess.Popen([str(binary), "run", "--no-config", "--hwdec", "no",
                                  "--profile-startup", *(["--paused"] if paused else []),
                                  *([] if loop else ["--no-loop"]), str(media)],
                                 env=env | ({"STILLWAVE_TEST_DROP_FIRST_RESTART": "1"} if suppress_restart else {})
                                 | ({"STILLWAVE_TEST_DELAY_END_FILE": "1"} if delay_end else {}),
                                 stdout=subprocess.DEVNULL, stderr=log)
        log.close()
        if wait_frame:
            wait_for(lambda: "first frame submitted" in log_path.read_text())
        else:
            wait_for(lambda: bool(list(base.glob("stillwave-*/control.sock"))))

    try:
        assert "no running instance" in command("hide", 1).stderr
        start()
        # A second foreground run must not reach Wayland or graphics setup.
        before = compositor.connections
        duplicate = command("run", 2, extra_args=("--no-config", str(media)))
        assert "already running" in duplicate.stderr
        assert compositor.connections == before
        assert len(list(base.glob("stillwave-*/control.sock"))) == 1
        socket_path = next(base.glob("stillwave-*/control.sock"))
        config_dir = base / "config" / "stillwave"
        config_dir.mkdir(parents=True)
        (config_dir / "config.json").write_text("{broken config")

        # Absolute/relative names and symlink aliases address the same owner.
        alias = base / "alias"
        alias.symlink_to(base / "wayland-test")
        command("show", extra_env={"WAYLAND_DISPLAY": str(alias)})
        command("show", extra_env={"WAYLAND_DISPLAY": str(base / "wayland-test")})
        assert "no running instance" in command("show", 1, {"WAYLAND_DISPLAY": "other-session"}).stderr

        hides = compositor.hides
        unloads = log_path.read_text().count("playback unloaded")
        command("hide")
        command("hide")
        wait_for(lambda: compositor.hides == hides + 1)
        wait_for(lambda: log_path.read_text().count("playback unloaded") == unloads + 1)
        swaps = compositor.swaps
        time.sleep(0.35)
        assert compositor.swaps == swaps, "rendering continued while explicitly hidden"
        count = log_path.read_text().count("show to first frame")
        command("show")
        wait_for(lambda: log_path.read_text().count("show to first frame") == count + 1)
        command("show")  # Idempotent, no reload/remap.
        time.sleep(0.05)
        assert log_path.read_text().count("show to first frame") == count + 1

        # Malformed requests are rejected and do not kill the owner.
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as raw:
            raw.bind("")
            raw.settimeout(2)
            for payload in (b"", b"bad", b"x", b"hide"):
                raw.sendto(payload, str(socket_path))
                assert raw.recv(2) == b"E"

        for _ in range(6):
            command("hide")
            command("show")
        command("hide")
        time.sleep(0.25)
        swaps = compositor.swaps
        time.sleep(0.25)
        assert compositor.swaps == swaps
        wait_for(lambda: "playback unloaded" in log_path.read_text())
        count = log_path.read_text().count("show to first frame")
        command("show")
        wait_for(lambda: log_path.read_text().count("show to first frame") > count)
        text = log_path.read_text()
        assert text.count("mpv OpenGL render context created") == 1, text
        assert text.count("EGL context initialized") == 1, text
        assert text.count("EGL window initialized") == 1, text
        command("quit")
        assert owner.wait(10) == 0
        assert not socket_path.exists()
        assert "no running instance" in command("show", 1).stderr

        # Restart after cleanup, then paused-at-zero hide/show and hidden quit.
        start(paused=True)
        command("hide")
        wait_for(lambda: "playback unloaded" in log_path.read_text())
        command("show")
        wait_for(lambda: "show to first frame" in log_path.read_text())
        command("hide")
        command("quit")
        assert owner.wait(10) == 0

        # Hide while startup is still in progress, before a player may exist.
        start(wait_frame=False)
        command("hide")
        time.sleep(0.2)
        swaps = compositor.swaps
        time.sleep(0.2)
        assert compositor.swaps == swaps
        command("show")
        wait_for(lambda: "first frame submitted" in log_path.read_text())
        command("quit")
        assert owner.wait(10) == 0

        # Cancel a load whose readiness milestone never arrived. This used to
        # leave loading_epoch stuck if pause was merely replaced with stop.
        start(suppress_restart=True, wait_frame=False)
        wait_for(lambda: "first playback restart suppressed" in log_path.read_text())
        command("hide")
        wait_for(lambda: "playback unloaded" in log_path.read_text())
        command("show")
        wait_for(lambda: "show to first frame" in log_path.read_text())
        command("quit")
        assert owner.wait(10) == 0

        # An old END_FILE delivered during idle confirmation must be drained
        # before starting the next load, not cancel that new load accidentally.
        start(delay_end=True)
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as raw:
            raw.bind("")
            raw.settimeout(5)
            raw.sendto(b"h", str(socket_path))
            raw.sendto(b"s", str(socket_path))
            assert raw.recv(2) == b"K"
            assert raw.recv(2) == b"K"
        wait_for(lambda: "END_FILE delayed until idle query" in log_path.read_text())
        wait_for(lambda: "show to first frame" in log_path.read_text())
        command("quit")
        assert owner.wait(10) == 0

        # Non-looping EOF still exits normally. An unloaded hidden player must
        # stay controllable past the former video duration and reload on show.
        start(loop=False)
        assert owner.wait(10) == 0, log_path.read_text()
        start(loop=False, suppress_restart=True, wait_frame=False)
        wait_for(lambda: "first playback restart suppressed" in log_path.read_text())
        assert owner.wait(10) == 0, log_path.read_text()
        start(loop=False)
        command("hide")
        wait_for(lambda: "playback unloaded" in log_path.read_text())
        time.sleep(2.2)
        assert owner.poll() is None, log_path.read_text()
        command("show")
        wait_for(lambda: "show to first frame" in log_path.read_text())
        assert owner.wait(10) == 0, log_path.read_text()

        # Crash recovery retains the lock inode but replaces the stale socket.
        start()
        owner.kill()
        owner.wait(10)
        assert socket_path.exists()
        start()
        command("quit")
        assert owner.wait(10) == 0
        assert not socket_path.exists()
    finally:
        if owner is not None and owner.poll() is None:
            owner.kill()
            owner.wait(10)
        compositor.close()

print("Control/lifecycle checks passed (real libmpv + offscreen Mesa; no desktop surfaces)")
