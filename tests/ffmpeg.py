#!/usr/bin/env python3
"""Integrated FFmpeg backend: real software decode + llvmpipe; no desktop/CUDA."""
import atexit
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from wayland_fixture import Compositor

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/stillwave").resolve()
root = Path(__file__).resolve().parents[1]
children = []


@atexit.register
def cleanup():
    for p in children:
        if p.poll() is None:
            p.kill()
            p.wait(10)


with tempfile.TemporaryDirectory(prefix="sw-ffmpeg-") as tmp:
    base = Path(tmp)
    mesa = next(Path("/usr/share/glvnd/egl_vendor.d").glob("*mesa*.json"))
    software = os.environ | {"__EGL_VENDOR_LIBRARY_FILENAMES": str(mesa), "LIBGL_ALWAYS_SOFTWARE": "1"}
    shader_test = base / "shader-test"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(root / "tests/yuv.c"),
                    str(root / "src/render/yuv.c"), "-o", str(shader_test), "-lEGL", "-lGL", "-lm"], check=True)
    subprocess.run([str(shader_test)], env=software, check=True, timeout=20)
    shim = base / "egl.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/headless-egl.c"), "-o", str(shim), "-ldl", "-lwayland-client"], check=True)
    video = base / "red.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=red:size=98x66:rate=10",
                    "-t", "1", "-c:v", "mpeg4", "-bf", "2", str(video)], check=True)
    unsupported = base / "unsupported.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10",
                    "-t", "0.2", "-pix_fmt", "yuv444p", "-c:v", "ffv1", str(unsupported)], check=True)
    tenbit = base / "10bit.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=red:size=98x66:rate=10",
                    "-t", "0.2", "-pix_fmt", "yuv420p10le", "-c:v", "ffv1", str(tenbit)], check=True)
    pattern = base / "quadrants.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "color=red:size=98x66:rate=10,drawbox=x=49:y=0:w=49:h=33:color=lime:t=fill,"
                    "drawbox=x=0:y=33:w=49:h=33:color=blue:t=fill,"
                    "drawbox=x=49:y=33:w=49:h=33:color=white:t=fill",
                    "-vf", "scale=in_color_matrix=bt601:out_color_matrix=bt709", "-colorspace", "bt709",
                    "-t", "0.2", "-c:v", "ffv1", str(pattern)], check=True)
    env = software | {"XDG_RUNTIME_DIR": tmp, "WAYLAND_DISPLAY": str(base / "wayland"),
                      "XDG_CONFIG_HOME": str(base / "config"), "DISPLAY": "", "LD_PRELOAD": str(shim),
                      "PROBE_TEST_READBACK": "1"}
    env.pop("WAYLAND_SOCKET", None)
    compositor = Compositor(base / "wayland", scale=[1, 2], outputs=2)

    class Run:
        def __init__(self, args=(), media=video, delay=False, grid=False, hdr=False):
            self.log = base / f"log-{time.monotonic_ns()}"
            with self.log.open("w") as log:
                self.p = subprocess.Popen([str(binary), "run", "--no-config", "--backend", "ffmpeg",
                                          "--hwdec", "no", "--profile-startup", *args, str(media)],
                                         env=env | ({"STILLWAVE_TEST_OPEN_DELAY_MS": "500"} if delay else {})
                                         | ({"PROBE_TEST_READBACK_GRID": "1"} if grid else {})
                                         | ({"STILLWAVE_TEST_HDR": "1"} if hdr else {}),
                                         stdout=subprocess.DEVNULL, stderr=log)
            children.append(self.p)

        def text(self):
            return self.log.read_text()

        def until(self, condition):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if condition():
                    return
                assert self.p.poll() is None, self.text()
                assert not compositor.failures, compositor.failures
                time.sleep(.01)
            raise AssertionError("timed out\n" + self.text())

        def wait(self, marker, count=1):
            self.until(lambda: self.text().count(marker) >= count)

        def command(self, name):
            before = time.monotonic()
            result = subprocess.run([str(binary), name], env=env, capture_output=True, text=True, timeout=5)
            assert result.returncode == 0, (result.stderr, self.text())
            return time.monotonic() - before

        def quit(self):
            self.command("quit")
            assert self.p.wait(10) == 0, self.text()

    try:
        run = Run()
        run.wait("first frame submitted", 2)
        assert "[TEST-1] configured 64x64, buffer 64x64" in run.text()
        assert "[TEST-2] configured 64x64, buffer 128x128" in run.text()
        for _ in range(3):
            releases = run.text().count("FFmpeg playback/video resources released")
            run.command("hide")
            run.command("hide")
            run.wait("FFmpeg playback/video resources released", releases + 2)
            count = compositor.swaps
            time.sleep(.15)
            assert compositor.swaps == count
            shows = run.text().count("show to first frame submitted")
            run.command("show")
            run.wait("show to first frame submitted", shows + 2)
        pixels = re.findall(r"pixel=(\d+),(\d+),(\d+),(\d+)", run.text())
        assert pixels and all(int(r)>240 and int(g)<15 and int(b)<15 for r,g,b,a in pixels), pixels
        assert "mpv OpenGL render context" not in run.text()
        assert run.text().count("YUV GPU shader initialized") == 2
        # Retire outputs asynchronously; no selected outputs must not exit run.
        compositor.remove_output(1)
        time.sleep(.2)
        compositor.remove_output(0)
        time.sleep(.2)
        assert run.p.poll() is None, run.text()
        run.command("hide")
        compositor.add_output(2)
        time.sleep(.15)
        assert "[TEST-3]" not in run.text()
        run.command("show")
        run.wait("[TEST-3] configured")
        run.quit()

        # Paused startup and show each render once, then wait without a draw loop.
        run = Run(("--paused",), media=tenbit)
        run.wait("first frame submitted")
        before = compositor.swaps
        time.sleep(.3)
        assert compositor.swaps == before
        run.command("hide")
        run.wait("FFmpeg playback/video resources released")
        run.command("show")
        run.wait("show to first frame submitted")
        run.quit()

        # Hide may arrive before any surface/player is initialized.
        run = Run()
        run.until(lambda: bool(list(base.glob("stillwave-*/control.sock"))))
        run.command("hide")
        count = compositor.swaps
        time.sleep(.15)
        assert compositor.swaps == count
        run.command("show")
        run.wait("first frame submitted")
        run.quit()

        # Nonlooping completion includes submission of the final decoded frame.
        run = Run(("--no-loop",))
        assert run.p.wait(10) == 0, run.text()
        assert "first frame submitted" in run.text()

        run = Run(("--no-loop",))
        run.wait("first frame submitted")
        run.command("hide")
        run.wait("FFmpeg playback/video resources released")
        time.sleep(1.2)
        assert run.p.poll() is None, run.text()
        run.command("show")
        run.wait("show to first frame submitted")
        assert run.p.wait(10) == 0, run.text()

        # Even when opening/device work cannot be interrupted, controls stay live.
        run = Run(delay=True)
        run.wait("[TEST-3] configured")
        assert run.command("hide") < .3
        assert run.command("show") < .3
        assert run.command("hide") < .3
        assert run.command("show") < .3
        run.wait("show to first frame submitted")
        run.quit()

        # Withheld callbacks do not stall decoding, teardown, or paused redraw.
        compositor.callbacks_enabled = False
        run = Run()
        run.wait("first frame submitted")
        time.sleep(.3)
        run.command("hide")
        run.wait("FFmpeg playback/video resources released")
        compositor.callbacks_enabled = True
        run.command("show")
        run.wait("show to first frame submitted")
        run.quit()

        compositor.callbacks_enabled = False
        run = Run(("--no-loop",))
        assert run.p.wait(10) == 0, run.text()
        assert "EOF presentation grace expired" in run.text()
        compositor.callbacks_enabled = True

        run = Run(("--paused",), media=pattern, grid=True)
        run.wait("first frame submitted")
        samples = {key: tuple(map(int, values.split(","))) for key, values in
                   re.findall(r"sample=(TL|TR|BL|BR) rgba=([0-9,]+)", run.text())}
        assert set(samples) == {"TL", "TR", "BL", "BR"}, run.text()
        for key, expected in {"TL": (255,0,0), "TR": (0,255,0), "BL": (0,0,255), "BR": (255,255,255)}.items():
            assert all(abs(a-b)<25 for a,b in zip(samples[key][:3], expected)), samples
        run.quit()

        run = Run(media=unsupported)
        assert run.p.wait(10) == 1, run.text()
        assert "unsupported pixel format yuv444p" in run.text()
        assert "use --backend mpv" in run.text()
        run = Run(hdr=True)
        assert run.p.wait(10) == 1, run.text()
        assert "HDR tone mapping unsupported" in run.text()
    finally:
        for p in children:
            if p.poll() is None:
                p.kill()
                p.wait(10)
        compositor.close()

print("Integrated FFmpeg lifecycle/control/multi-output tests passed (no CUDA/desktop surfaces)")
