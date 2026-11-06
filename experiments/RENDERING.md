# FFmpeg rendering probe (milestone 2)

`ffmpeg-render-probe` is a **separate experimental executable**, not a change to
Stillwave. It shares the decoding/lifecycle harness with `ffmpeg-probe` and adds
one Wayland layer-shell background surface plus a small desktop OpenGL renderer.
It does not use mpv or CUDA/OpenGL interoperability.

## Build and run

In addition to milestone 1's FFmpeg libraries, this target needs `libswscale`,
Wayland client/EGL, desktop EGL/OpenGL, and the project's protocol generation
requirements (the same installed libraries/tools used by Stillwave).

```sh
zig build ffmpeg-render-probe -Doptimize=ReleaseSafe
./zig-out/bin/ffmpeg-render-probe --decoder cuda /absolute/path/to/video.mp4 2>probe-render-cuda.log
```

Use `--decoder software` for a CPU-decoding comparison. CUDA mode still requires
actual CUDA frames and successful downloads; it never silently falls back.
The target is opt-in and is not installed by ordinary builds or `install-system`.
The decode-only `ffmpeg-probe` remains available and unchanged in scope.

The probe **starts hidden**. In its terminal, enter newline-delimited commands:

```text
show
hide
show
hide
quit
```

Wait a few seconds in each state. Each show starts the video from the beginning.
Repeated show while decoding, or repeated hide, is harmless. EOF on stdin,
Ctrl-C, and SIGTERM perform cleanup and exit. No IPC/daemon is implemented.

By default, it uses the **first connected output announced by Wayland**. Select
exactly one output explicitly when needed:

```sh
./zig-out/bin/stillwave list-outputs
./zig-out/bin/ffmpeg-render-probe --decoder cuda --output DP-1 /path/to/video.mp4 2>probe-render-cuda.log
```

Named selection requires `wl_output` v4 names; there is no hard-coded connector
name. Layer-shell is required; there is no normal-window fallback. The surface
uses the background layer, requests no keyboard focus, and has an empty input
region. Other wallpaper providers may cover it: **do not run Stillwave playback
and this probe together when judging visibility or comparing memory**. Stop your
other test process yourself; the probe never stops providers or edits settings.

## Frame path

```text
FFmpeg decoder
  -> CUDA-to-CPU download (CUDA mode only)
  -> libswscale CPU conversion to RGBA
  -> bounded one-frame mailbox
  -> OpenGL texture upload/draw
  -> EGL swap to the Wayland background surface
```

Decoding follows timestamps and loops. The worker replaces the mailbox's old
frame rather than waiting for compositor callbacks, so hidden-by-fullscreen
surfaces cannot stall decoder shutdown or build an unbounded frame queue. Such
coverage does not automatically unload playback: use `hide` for resource release.

The owner/main thread exclusively owns Wayland/EGL/OpenGL. It respects the initial
configure handshake, frame callbacks, and a sync barrier between unmap/remap.
Integer output scale and compositor-provided logical sizes determine buffer size;
physical monitor geometry is not used. Video fills the surface, cropping while
preserving sample/display aspect ratio. The renderer corrects row orientation and
handles padded RGBA strides.

## Hide resources and memory expectations

On hide:

1. Signal worker cancellation and wake timestamp waits.
2. Unmap the wallpaper and cancel frame presentation callbacks.
3. Delete the video texture and finish outstanding GL work.
4. Join the worker, freeing FFmpeg frames, decoder, demuxer, CUDA-device references,
   conversion buffers, and swscale state.
5. Release any queued CPU frame.

The **EGL context/window, shader program, and tiny vertex buffer stay alive** for
reuse. EGL back buffers and driver/context allocations may remain; zero hidden
VRAM is not promised. Compositor-held buffers may be released asynchronously.
Final quit destroys the retained graphics resources too.

As with milestone 1, CUDA initialization/transfer and filesystem operations are
not fully interruptible. Hide can block until those operations return. The
worker never waits for the render owner, so joining it cannot deadlock on a
pending Wayland frame callback.

## Measurements

Keep the video, build mode, output, and decoder choice fixed. In another terminal:

```sh
watch -n 0.5 nvidia-smi
# Full process list includes GL-only retained allocations while hidden.
# --query-compute-apps alone may omit a process once its CUDA context is gone.
top -p PID
```

Use the PID printed at startup. Record GPU memory and CPU usage before first
show, during playback, after `hide_completed` plus a short delay, during repeated
shows/hides (at least five cycles), and after quit.

New log fields:

| Marker | Meaning |
| --- | --- |
| `presentation_initialized` | Wayland discovery and EGL context setup before the initial hidden baseline |
| `gl_initialized` | First window/current-context/shader initialization; should appear only once |
| `first_frame_submitted` | **Show request to first completed EGL swap** for that cycle |
| `first_upload_ms`, `first_draw_ms`, `first_swap_ms` | First frame's CPU-side API timings |
| `conversion_total_ms` | Worker-side color-conversion time for that session |
| `submitted`, `replaced_frames` | Submitted frames and mailbox replacements while rendering was delayed |
| `upload_total_ms`, `draw_total_ms`, `swap_total_ms` | Owner-side accumulated API time for that cycle |
| `video_texture_released` | Video texture deleted; retained graphics resources listed |
| `video_buffers_released` | Worker joined and queued CPU frame released |
| `hide_completed` | Hide handling through texture and decoder/frame cleanup |

The original decode/download/device/open/teardown timings are still present.
`session_released` covers worker-owned objects; use **`hide_completed`**, not just
that worker marker, for the complete hidden-memory sample. Compare later shows
separately from the first, which additionally initializes the EGL window/GL
renderer. Initial `presentation_initialized` is outside show latency.

Swap completion is **not confirmed compositor presentation or user visibility**.
GL calls are asynchronous: draw/upload CPU-side timings are not GPU execution
timings. Copying 4K frames through CPU memory and uploading RGBA can be expensive;
measure sustained CPU use and submitted-frame rate, not just first-frame latency.

## Deliberate limits

- One output, one video, no audio/config/IPC/service installation.
- SDR conversion only. PQ/HLG is rejected; there is no HDR tone mapping, color
  management, dithering pipeline, or metadata-based video rotation.
- Supported matrix metadata is honored; unsupported explicit matrices fail.
  Unspecified matrix metadata uses swscale's default BT.601 assumption.
- Integer scale only (no fractional-scale/viewporter integration yet).
- Selected-output removal or compositor close is an error; no hotplug recovery.
- `--frames N` ends decoding but leaves the last submitted texture visible until
  hide/show/quit. It does not represent continuous playback after that point.

## Non-desktop tests

```sh
python3 tests/ffmpeg-render-probe.py
```

Requires `cc`, `ffmpeg`, `readelf`, Mesa EGL vendor configuration, and software GL.
Tests force Mesa/llvmpipe and use a fake Wayland server plus an offscreen-pbuffer
EGL shim. Real FFmpeg conversion and GL draws/readback verify repeated lifecycle,
retained EGL reuse, texture release, configure-before-swap, integer scaling,
withheld callbacks, rapid transitions, failure cleanup, and asymmetric BT.709
pixels with padded strides. No CUDA decoding or desktop surfaces are used.

The shim does not exercise actual Wayland EGL buffer attachment/remapping. Real
NVIDIA/compositor behavior, visibility, CPU performance, and VRAM savings must
still be validated manually. Stillwave now has an opt-in native-YUV GPU-conversion
backend; mpv remains the default. See [integrated backend details](../FFMPEG_BACKEND.md).
This experiment remains the CPU-RGBA-conversion baseline.
