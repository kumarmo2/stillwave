#!/usr/bin/env python3
"""Real FFmpeg + offscreen Mesa rendering; fake Wayland, no CUDA/desktop surfaces."""
import atexit
from pathlib import Path
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from wayland_fixture import Compositor

root = Path(__file__).resolve().parents[1]
binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/ffmpeg-render-probe").resolve()
children = []


@atexit.register
def cleanup():
    for child in children:
        if child.poll() is None:
            child.kill()
            child.wait(10)


with tempfile.TemporaryDirectory(prefix="ff-render-test-") as tmp:
    base = Path(tmp)
    shim = base / "egl.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/headless-egl.c"), "-o", str(shim),
                    "-ldl", "-lwayland-client"], check=True, timeout=30)
    video = base / "red.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=red:size=96x64:rate=10",
                    "-t", "1", "-c:v", "mpeg4", "-bf", "2", str(video)], check=True, timeout=20)
    mesa = next(Path("/usr/share/glvnd/egl_vendor.d").glob("*mesa*.json"), None)
    assert mesa is not None, "Mesa EGL vendor JSON is required for offscreen tests"
    pattern = base / "quadrants.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "color=red:size=98x66:rate=10,drawbox=x=49:y=0:w=49:h=33:color=lime:t=fill,"
                    "drawbox=x=0:y=33:w=49:h=33:color=blue:t=fill,"
                    "drawbox=x=49:y=33:w=49:h=33:color=white:t=fill",
                    "-vf", "scale=in_color_matrix=bt601:out_color_matrix=bt709",
                    "-colorspace", "bt709", "-color_trc", "bt709", "-color_primaries", "bt709",
                    "-t", "1", "-c:v", "ffv1", str(pattern)], check=True, timeout=20)
    env = os.environ | {"XDG_RUNTIME_DIR": tmp, "WAYLAND_DISPLAY": str(base / "wayland-test"),
                        "DISPLAY": "", "LD_PRELOAD": str(shim), "LIBGL_ALWAYS_SOFTWARE": "1",
                        "PROBE_TEST_READBACK": "1", "__EGL_VENDOR_LIBRARY_FILENAMES": str(mesa)}
    env.pop("WAYLAND_SOCKET", None)
    compositor = Compositor(base / "wayland-test", scale=2)

    class Run:
        def __init__(self, extra=(), media=video, grid=False):
            self.path = base / f"log-{time.monotonic_ns()}"
            with self.path.open("w") as log:
                self.p = subprocess.Popen([str(binary), "--decoder", "software", *extra, str(media)],
                                          env=env | ({"PROBE_TEST_READBACK_GRID": "1"} if grid else {}),
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=log, text=True)
            children.append(self.p)

        def text(self):
            return self.path.read_text()

        def wait(self, needle, count=1):
            self.until(lambda: self.text().count(needle) >= count)

        def until(self, predicate):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if predicate():
                    return
                assert self.p.poll() is None, self.text()
                assert not compositor.failures, compositor.failures
                time.sleep(.01)
            raise AssertionError("timed out\n" + self.text())

        def send(self, text):
            self.p.stdin.write(text + "\n")
            self.p.stdin.flush()

        def finish(self, status=0, eof=False):
            if eof:
                self.p.stdin.close()
            else:
                self.send("quit")
            assert self.p.wait(10) == status, self.text()
            assert not self.p.stdout.read()
            self.p.stdout.close()
            if not self.p.stdin.closed:
                self.p.stdin.close()

    try:
        run = Run(("--output", "TEST-1"))
        run.wait("stage=ready")
        assert "scale=2 state=hidden" in run.text()
        assert compositor.swaps == 0  # Startup must not map a wallpaper.
        for cycle in range(1, 4):
            run.send("show")
            run.wait(f"cycle={cycle} stage=first_frame_submitted")
            run.send("show")
            run.wait(f"cycle={cycle} stage=already_showing")
            run.send("hide")
            run.wait(f"cycle={cycle} stage=hide_completed")
            run.until(lambda: compositor.hides >= cycle)
            swaps = compositor.swaps
            time.sleep(.15)
            assert compositor.swaps == swaps
            assert f"cycle={cycle} stage=video_buffers_released" in run.text()
            run.send("hide")
        assert run.text().count("[render] gl_initialized") == 1, run.text()
        assert run.text().count("[render] egl_initialized") == 1, run.text()
        assert run.text().count("video_texture_released") == 3, run.text()
        pixels = re.findall(r"pixel=(\d+),(\d+),(\d+),(\d+)", run.text())
        assert pixels, run.text()
        assert all(int(r) > 240 and int(g) < 15 and int(b) < 15 and int(a) > 240
                   for r, g, b, a in pixels), pixels

        # Compositor-covered surfaces withhold callbacks: no rendering busy loop,
        # bounded latest-frame queue, and hide must still join/unload promptly.
        compositor.callbacks_enabled = False
        run.send("show")
        run.wait("cycle=4 stage=first_frame_submitted")
        time.sleep(.4)
        count = compositor.swaps
        time.sleep(.3)
        assert compositor.swaps == count
        run.send("hide")
        run.wait("cycle=4 stage=hide_completed")
        assert re.search(r"cycle=4 submitted=1 replaced_frames=[1-9]", run.text()), run.text()
        compositor.callbacks_enabled = True
        run.send("show")
        run.wait("cycle=5 stage=first_frame_submitted")
        # Rapid transitions before a configure or a decoded frame is ready.
        for _ in range(5):
            run.send("hide\nshow")
        run.wait("cycle=10 stage=first_frame_submitted")
        run.finish(eof=True)
        assert "error=" not in run.text(), run.text()

        # Frame-limited sessions release decoder state but can leave the final
        # texture visible until explicit hide; show then starts a new cycle.
        run = Run(("--frames", "3"))
        run.wait("stage=ready")
        run.send("show")
        run.wait("outcome=frame_limit")
        run.wait("stage=first_frame_submitted")
        run.send("hide")
        run.wait("stage=video_buffers_released")
        run.send("show")
        run.wait("cycle=2 stage=first_frame_submitted")
        run.p.send_signal(signal.SIGTERM)
        assert run.p.wait(10) == 0, run.text()
        run.p.stdin.close()
        run.p.stdout.close()

        # Asymmetric BT.709 input and padded RGBA rows verify orientation,
        # source stride, aspect-fill cropping, and explicit color metadata.
        run = Run(media=pattern, grid=True)
        run.wait("stage=ready")
        run.send("show")
        run.wait("stage=first_frame_submitted")
        samples = {label: tuple(map(int, values.split(","))) for label, values in
                   re.findall(r"sample=(TL|TR|BL|BR) rgba=([0-9,]+)", run.text())}
        assert set(samples) == {"TL", "TR", "BL", "BR"}, run.text()
        for label, expected in {"TL": (255, 0, 0), "TR": (0, 255, 0),
                                "BL": (0, 0, 255), "BR": (255, 255, 255)}.items():
            assert all(abs(a - b) < 25 for a, b in zip(samples[label][:3], expected)), samples
        run.finish()

        bad = subprocess.run([str(binary), "--output", "MISSING", str(video)], env=env,
                             capture_output=True, text=True, timeout=10)
        assert bad.returncode == 1 and "requested output unavailable" in bad.stderr, bad.stderr
        corrupt = base / "bad.mp4"
        corrupt.write_bytes(b"invalid video")
        run = Run(media=corrupt)
        run.wait("stage=ready")
        run.send("show")
        run.wait("stage=session_released")
        run.wait("stage=hide_completed")
        run.finish(status=1)

        needed = subprocess.run(["readelf", "-d", str(binary)], capture_output=True,
                                text=True, check=True).stdout
        assert "libmpv" not in needed
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(10)
        compositor.close()

print("FFmpeg renderer lifecycle/pixel tests passed (offscreen Mesa; no CUDA or desktop surfaces)")
