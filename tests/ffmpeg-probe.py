#!/usr/bin/env python3
"""Software-only lifecycle tests. Never creates a CUDA device or desktop surface."""
import atexit
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/ffmpeg-probe").resolve()
root = Path(__file__).resolve().parents[1]
children = []


@atexit.register
def cleanup():
    for child in children:
        if child.poll() is None:
            child.kill()
            child.wait(10)

with tempfile.TemporaryDirectory(prefix="ffmpeg-probe-test-") as tmp:
    base = Path(tmp)
    clock_test = base / "clock-test"
    flags = subprocess.run(["pkg-config", "--cflags", "--libs", "libavformat", "libavcodec", "libavutil"],
                           capture_output=True, text=True, check=True).stdout.split()
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(root / "tests/ffmpeg-probe-clock.c"), "-o", str(clock_test),
                    *flags, "-lm", "-pthread"], check=True, timeout=30)
    subprocess.run([str(clock_test)], check=True, timeout=5)
    video = base / "bframes.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10",
                    "-t", "1", "-c:v", "mpeg4", "-bf", "2", str(video)], check=True, timeout=20)
    offset = base / "offset.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(video), "-c", "copy",
                    "-output_ts_offset", "5", str(offset)], check=True, timeout=20)
    unsupported = base / "ffv1.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10",
                    "-t", "0.2", "-c:v", "ffv1", str(unsupported)], check=True, timeout=20)
    audio = base / "audio.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440",
                    "-t", "0.1", str(audio)], check=True, timeout=20)
    corrupt = base / "corrupt.mp4"
    corrupt.write_bytes(b"not a video")
    playlist = base / "playlist.ffconcat"
    playlist.write_text(f"ffconcat version 1.0\nfile '{video}'\n")

    def cli(*args, status=2):
        result = subprocess.run([str(binary), *map(str, args)], input="", text=True,
                                capture_output=True, timeout=10)
        assert result.returncode == status, (args, result.returncode, result.stderr)
        return result

    assert "No video is displayed" in cli("--help", status=0).stdout
    for args in [(), (video, video), ("--decoder", "bad", video), ("--decoder",),
                 ("--frames", "0", video), ("--frames", "-1", video),
                 ("--frames", "18446744073709551616", video),
                 ("--decoder", "software", "--decoder", "cuda", video),
                 ("--device", "0", video), (base,), (base / "missing",)]:
        cli(*args)
    fifo = base / "fifo"
    os.mkfifo(fifo)
    cli(fifo)

    class Run:
        def __init__(self, media=video, args=()):
            self.path = base / f"log-{time.monotonic_ns()}"
            with self.path.open("w") as log:
                self.p = subprocess.Popen([str(binary), *args, str(media)],
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=log, text=True)
            children.append(self.p)
            self.wait("stage=ready")

        def text(self):
            return self.path.read_text()

        def wait(self, needle, count=1):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.text().count(needle) >= count:
                    return
                assert self.p.poll() is None, self.text()
                time.sleep(.01)
            raise AssertionError(f"timed out waiting for {needle}\n{self.text()}")

        def send(self, text):
            self.p.stdin.write(text + "\n")
            self.p.stdin.flush()

        def finish(self, expected=0, eof=False):
            if eof:
                self.p.stdin.close()
            else:
                self.send("quit")
            assert self.p.wait(10) == expected, self.text()
            assert not self.p.stdout.read()
            assert "stage=hide_completed" in self.text()
            self.p.stdout.close()
            if not self.p.stdin.closed:
                self.p.stdin.close()

    run = Run()
    baseline_fds = len(list(Path(f"/proc/{run.p.pid}/fd").iterdir()))
    for cycle in range(1, 4):
        run.send("show")
        run.wait(f"cycle={cycle} stage=first_frame_ready")
        run.send("show")
        run.wait(f"cycle={cycle} stage=already_showing")
        run.send("hide")
        run.wait(f"cycle={cycle} stage=hide_completed")
        assert len(list(Path(f"/proc/{run.p.pid}/fd").iterdir())) <= baseline_fds + 1
        assert len(list(Path(f"/proc/{run.p.pid}/task").iterdir())) == 1
        run.send("hide")
    run.send("nonsense")
    run.wait("unknown_command")
    run.send("x" * 300)
    run.wait("command_too_long")
    run.send("show\nhide")  # Cancel opening/probing without waiting for readiness.
    run.wait("cycle=4 stage=hide_completed")
    assert "cuda_device_created" not in run.text()
    run.finish()

    # 30 frames requires three passes of a ten-frame B-frame clip. This verifies
    # draining delayed output and loop-clock reset without silently losing frames.
    run = Run(args=("--frames", "30"))
    before = time.monotonic()
    run.send("show")
    run.wait("outcome=frame_limit")
    elapsed = time.monotonic() - before
    assert 2.5 < elapsed < 7, (elapsed, run.text())
    assert "loop=1 frames=10" in run.text() and "loop=2 frames=20" in run.text(), run.text()
    assert "frames=30 downloads=0" in run.text()
    # A completed-but-joinable worker can be restarted without a prior hide.
    run.send("show")
    run.wait("cycle=2 stage=first_frame_ready")
    run.finish(eof=True)

    run = Run(offset, ("--frames", "12"))
    before = time.monotonic()
    run.send("show")
    run.wait("outcome=frame_limit")
    assert time.monotonic() - before < 5, run.text()  # Nonzero PTS isn't an initial delay.
    assert "frames=12 downloads=0" in run.text()
    run.finish()

    for media in (corrupt, audio, unsupported, playlist):
        # FFV1 has no CUDA configuration: reject it before device creation, so
        # this strict-hardware-mode failure test still does not touch the GPU.
        run = Run(media, ("--decoder", "cuda") if media == unsupported else ())
        for cycle in (1, 2):
            run.send("show")
            run.wait(f"cycle={cycle} stage=session_released")
            assert f"cycle={cycle} error=" in run.text(), run.text()
            run.send("hide")
            run.wait(f"cycle={cycle} stage=hide_completed")
        assert "cuda_device_created" not in run.text()
        run.finish(expected=1)

    run = Run()
    run.send("show")
    run.wait("stage=first_frame_ready")
    run.p.send_signal(signal.SIGTERM)
    assert run.p.wait(10) == 0, run.text()
    assert "stage=session_released" in run.text()
    run.p.stdin.close()
    run.p.stdout.close()

    # The probe's direct dependencies must not include the production player or
    # presentation libraries (FFmpeg's own transitive dependencies may differ).
    dynamic = subprocess.run(["readelf", "-d", str(binary)], capture_output=True,
                             text=True, check=True).stdout
    needed = re.findall(r"Shared library: \[(.*?)\]", dynamic)
    assert not any(re.match(r"lib(mpv|EGL|GL|wayland).*", lib) for lib in needed), needed

print("FFmpeg probe software/lifecycle tests passed (no CUDA devices or desktop surfaces)")
