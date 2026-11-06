# Integrated FFmpeg backend

Stillwave supports two playback backends in the **same binary**:

- `mpv` (default): existing playback/audio functionality and renderer.
- `ffmpeg` (opt-in): explicit decoder/CUDA resource teardown, native YUV texture
  uploads, and GPU color conversion. Muted-only; no CPU color-conversion fallback.

## Try it

Stop your previous wallpaper test process yourself. Build and run the local binary:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/stillwave run --backend ffmpeg --profile-startup \
  /absolute/path/to/video.mp4 2>stillwave-ffmpeg.log
```

From another terminal or event script:

```sh
./zig-out/bin/stillwave hide
./zig-out/bin/stillwave show
./zig-out/bin/stillwave quit
```

`run` remains foreground-only and initially visible. The existing session lock,
control socket, signals, and exit codes apply to both backends. No extra runtime
executable/service is needed. Experimental probes remain development tools only.
The user-level PATH installation is **not** updated by an ordinary build.

Select a backend in JSON with `"backend": "ffmpeg"`; CLI selection overrides it.
Omitting the field preserves mpv. This is an additive schema-v1 field, but older
Stillwave binaries reject unknown keys, so use matching binary/config versions.

The integrated backend preserves output selection/hotplug, integer/fractional
surface scaling, fill/fit, looping, and paused-first-frame semantics through
Stillwave's existing Wayland/EGL layer. There is one decoder worker per output;
GPU-device memory and decode work may scale with the number of outputs.

`--no-mute` with FFmpeg fails before connecting to Wayland. Use mpv for audio.
`--hwdec auto` attempts CUDA where the codec/build/driver supports it, then may
retry software decoding **before publishing any frames**. It is not strict CUDA
mode; profiling logs identify the actual path. `--hwdec no` uses software decoding.
A decode failure after publishing frames is an error. Unsupported native pixel
formats/color metadata/HDR are explicit errors, not RGB-conversion fallbacks.

## Frame and resource path

```text
worker: libavformat/libavcodec -> CUDA frame download when applicable
       -> bounded CPU YUV frame mailbox -> eventfd wake
owner: take latest frame -> upload Y/UV or Y/U/V planes
       -> OpenGL fragment-shader YUV-to-RGB conversion -> EGL swap
```

There are **no direct libswscale calls/linkage in the FFmpeg backend**, no per-frame CPU
RGBA conversion, and no CUDA/OpenGL sharing. GPU-to-CPU downloads and CPU-to-GPU
plane uploads still exist. The worker paces by timestamps; delayed frames are
drained before looping. Timestamp origins, missing timestamps, backward jumps,
and the last frame's loop interval are handled explicitly.

A paused player decodes/publishes one real frame, then waits until canceled.
Covered backgrounds can withhold callbacks: the mailbox replaces old frames
instead of blocking the worker, and one retained CPU frame supports deferred
redraw. Explicit hide is required to unload; coverage alone does not stop decoding.

### Hide/show

Hide immediately invalidates the old generation, requests cancellation, unmaps
surfaces, clears CPU-frame references, and deletes video-plane textures on the
render owner. Decoder/CUDA teardown completes on the worker without joining or
blocking the control/event loop. Rapid show waits inside the worker for the old
session's resources to be freed before opening a fresh session from the beginning.
Stale frames and EOF from previous generations cannot satisfy current readiness.

The EGL context/windows, shader programs, and small vertex buffers remain alive.
OpenGL deletion/flush is asynchronous; the NVIDIA driver or compositor may retain
allocations temporarily. Hidden VRAM is not promised to reach zero. Final quit
releases the retained resources and joins workers; uninterruptible device/I/O work
can delay final shutdown. Output retirement similarly waits for decoder cleanup
without blocking the other outputs or control commands.

For nonlooping playback, the backend attempts to submit the final frame and
honors its final frame interval. If the compositor withholds a callback, a **500 ms
final-presentation grace period** prevents `--no-loop` from hanging forever. That
case can omit the final frame and is logged with profiling enabled. Submission
never proves compositor visibility.

## Formats and color scope

Native shader paths:

- NV12 (8-bit Y + interleaved UV).
- YUV420P/YUVJ420P (8-bit planar Y/U/V).
- P010LE (10-bit, high-bit-aligned in 16-bit Y/UV planes).
- YUV420P10LE (10-bit planar samples in low bits).

Uploads handle odd chroma dimensions, plane padding, negative/unrepresentable
strides via bounded **plane row copies only**, format/resolution changes, sample
aspect ratio, and fill/fit. No RGB conversion is used for stride normalization.
Limited/full ranges and BT.601, BT.709, FCC, SMPTE240M, and BT.2020 nonconstant
luminance matrices are supported. Chroma siting is used in sampling coordinates.
Unspecified matrix metadata uses an HD/SD heuristic (709 at width >=1280 or height
>576, otherwise 601); unspecified siting assumes left. CUDA downloads copy frame
properties explicitly so range/matrix/HDR detection survives the transfer.

PQ/HLG is rejected. There is no HDR tone mapping, full color management, wide-gamut
primary conversion, dithering, or metadata-based video rotation yet. Matrix
conversion alone is not color management. Other pixel formats (RGB, 4:2:2, 4:4:4,
other bit depths, etc.) fail clearly; choose `--backend mpv` for those files.

Inputs are readable local regular files with a file-only protocol whitelist and
common self-contained demuxers; playlists/indirection/network inputs are excluded.
Unsupported containers can still be played through the mpv backend.

## Build and verification

FFmpeg support is included by default, requiring development libraries for
`libavformat`, `libavcodec`, and `libavutil`; CUDA headers/SDK are not required.
To omit this backend and its FFmpeg linkage:

```sh
zig build -Dffmpeg=false -Doptimize=ReleaseSafe
```

Selecting FFmpeg in that build gives an explicit error. mpv remains linked and
available regardless. Experimental targets keep their own dependencies.

```sh
zig build test
python3 tests/cli.py
python3 tests/control.py          # mpv regression/lifecycle
python3 tests/ffmpeg.py           # FFmpeg integration + native shader tests
python3 tests/replacement.py      # set-video, persistence/failure/hidden/multi-output
```

The FFmpeg tests use real software decoding, forced Mesa/llvmpipe, fake Wayland,
and offscreen EGL. They check native plane formats (including 10-bit low bits),
ranges/matrices, chroma gradients/odd dimensions, negative/misaligned strides,
texture updates, color/orientation, paused/EOF behavior, withheld callbacks,
rapid controls during simulated slow opens, two mixed-scale outputs, and output
removal/reconnection. Headless tests do not validate real CUDA or Wayland-EGL
remapping on NVIDIA.

## Desktop acceptance

Use the same video/output/build as earlier measurements and record at least five
cycles. Compare process VRAM before/during/after hide and after quit; inspect the
full `nvidia-smi` process list (a GL-only hidden process may disappear from the
compute-only query). Also measure sustained CPU use/frame rate, not only latency.

With `--profile-startup`, look for:

- `YUV GPU shader initialized (no CPU color conversion)` once per output.
- `[OUTPUT/ffmpeg] first frame ready decoding=cuda|software ...` per show.
- Existing `show to first frame submitted` durations per retained output.
- `FFmpeg playback/video resources released (EGL retained)` after hide.

The release marker confirms worker/CPU reference release and issued GL texture
deletion, **not completed GPU reclamation or a byte-level VRAM guarantee**. Give
the driver a short settling interval before sampling. The integrated backend's
NVIDIA VRAM, CPU and latency improvements still require real desktop measurement;
the previous RGBA experiment is a baseline, not a guarantee for this new path.
