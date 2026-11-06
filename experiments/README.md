# FFmpeg lifecycle probe (milestone 1)

For the separate one-output rendering executable, see
[FFmpeg rendering probe (milestone 2)](RENDERING.md). Both are experimental;
Stillwave's default remains mpv; an opt-in integrated FFmpeg/GPU-conversion
backend is documented in [FFMPEG_BACKEND.md](../FFMPEG_BACKEND.md).

A separate, opt-in **decode-only** experiment. It does not replace Stillwave, open
a window, or change desktop configuration. No rendering, audio, IPC, or daemon.
The small C implementation is compiled by Zig and directly calls FFmpeg's C API;
it does not launch the `ffmpeg` executable during normal use.

## Build

Requires FFmpeg development libraries (`libavformat`, `libavcodec`, `libavutil`),
pkg-config, libc/pthreads, and the same Zig version as the project:

```sh
zig build ffmpeg-probe -Doptimize=ReleaseSafe
```

Executable: `zig-out/bin/ffmpeg-probe`. This target does not build Stillwave.
Ordinary builds and `install-system` do not install the probe. There is no direct
mpv/Wayland/EGL/OpenGL dependency, and no CUDA SDK/header dependency. CUDA mode
uses FFmpeg's dynamically loaded NVIDIA support and requires a compatible GPU,
driver, FFmpeg build, and supported video codec.

## Run

Use the **same video** for both modes:

```sh
./zig-out/bin/ffmpeg-probe --decoder software /absolute/path/to/video.mp4 2>probe-software.log
./zig-out/bin/ffmpeg-probe --decoder cuda /absolute/path/to/video.mp4 2>probe-cuda.log
```

Run them separately, not concurrently. The probe starts **hidden**, prints its
PID, and accepts newline-delimited commands on stdin:

```text
show
hide
show
hide
quit
```

Wait several seconds between commands to measure each stable state.
`show` starts decoding from the beginning; duplicate show while active is a no-op.
`hide` cancels decoding, wakes timestamp pacing, joins the worker, and releases
packets, frames, decoder, input, and the application's hardware-device reference.
A finished or failed session can be shown again. EOF on stdin, Ctrl-C, or SIGTERM
cleans up and quits. The input must be a readable regular local file; URLs and
FIFOs are rejected. Protocol access is restricted to `file`; playlist/indirection
demuxers are excluded with a format whitelist. This milestone accepts common
self-contained video containers (MOV/MP4, Matroska/WebM, AVI, MPEG-TS/PS, Ogg,
FLV, NUT, ASF, RM) and H.264/HEVC/AV1/IVF elementary input. Other formats fail
explicitly rather than fetching referenced network media.

Decoding follows frame timestamps and loops at EOF; it is **not** an unpaced
maximum-throughput benchmark. CUDA mode verifies CUDA-format frames and downloads
them to CPU memory. It never silently falls back to software. CPU downloads
deliberately avoid building CUDA/OpenGL sharing for this first experiment.

Optional flags:

- `--device INDEX`: CUDA device ordinal (default 0); only valid with CUDA mode.
- `--frames N`: end each session after N decoded frames; the command process
  remains alive so you can sample memory and start another session.
- `--`: end options, for filenames beginning with a dash.
- `--help`: usage.

Session errors are logged, cleaned up, and leave the command process usable;
the final exit status is 1 if any session failed. Invalid arguments/files exit 2.
A successful run exits 0. Timings/diagnostics go to stderr; only help uses stdout.

## Measure

In another terminal:

```sh
watch -n 0.5 nvidia-smi
# CUDA process attribution, rather than total GPU memory alone:
nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv
```

Use the PID printed by the probe and record:

1. Before the first show (no hardware device has been requested).
2. During stable decoding, after `first_frame_ready`.
3. After `hide_completed`, then again after a short delay.
4. During subsequent shows and hides (at least five cycles).
5. After quit, as the final baseline.

The process may disappear from NVIDIA's GPU process list after device teardown;
that is different from the command process exiting. Other applications can change
total GPU usage, so do not attribute total-memory differences to the probe alone.

### Log stages

Each timing line contains process elapsed time, a cycle number, and
`duration_ms`:

| Stage | Duration means |
| --- | --- |
| `input_opened` | Opening the input |
| `stream_info_ready` | Stream probing |
| `cuda_device_created` | FFmpeg CUDA device/context creation |
| `decoder_opened` | Codec opening (some initialization is deferred until decode) |
| `first_frame_decoded` | Show request to first decoded frame |
| `first_frame_downloaded` | Show request to first successful CUDA-to-CPU transfer |
| `first_frame_ready` | Show request to first CPU-accessible frame |
| `session_released` | Freeing all session-owned FFmpeg references |
| `hide_completed` | Hide handling through worker join/resource release |

The session summary reports decoded frames, successful downloads, loop count,
total measured download time, and completion reason. In a successful CUDA session,
download count must match frame count. Cancellation or transfer failure can leave
a partial final frame, so inspect completion reason and errors too.

**These are not wallpaper appearance timings.** The earlier mpv show results
(~80–117 ms) include rendering/submission; this probe does not. A later rendering
prototype is needed for an apples-to-apples comparison.

The `session_released` / `hide_completed` markers mean application references
are released, **not** a guarantee that the NVIDIA driver immediately returns VRAM.
FFmpeg cancellation is cooperative: CUDA initialization/transfer or uninterruptible
filesystem work can delay hide even though timestamp waits are promptly canceled.

Also measure CPU usage during stable decode (for example, `top -p PID`). Software
decoding and GPU-to-CPU downloads have CPU/memory-bandwidth costs; low hidden VRAM
alone does not establish that either path is a good 4K wallpaper backend.

## Tests and next decision

```sh
python3 tests/ffmpeg-probe.py
```

Tests require `cc`, `ffmpeg` (fixture generation), and `readelf`; they use small software
decodes and reject an unsupported CUDA codec **before creating a device**.
Coverage includes repeated cycles, idempotence, cancellation, B-frame draining,
paced loops, nonzero/missing timestamps, long frame intervals, playlist rejection,
failure cleanup/retry, EOF/signal cleanup, and FD/thread release. They do not validate hardware decoding or NVIDIA VRAM return.

**Do not integrate or replace Stillwave yet.** The separate
[rendering probe](RENDERING.md) now adds one-output Wayland/EGL presentation with
texture upload. Compare its submission latency, sustained CPU use, and hidden
VRAM on the target GPU before deciding to migrate. GPU interoperability remains
deferred until copies are the measured bottleneck.
