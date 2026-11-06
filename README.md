# Stillwave (proof of concept)

CLI-only local video wallpapers, implemented in Zig using Wayland layer-shell,
EGL/OpenGL, and libmpv (default) or an opt-in direct FFmpeg backend. A wallpaper uses the **background** layer: ordinary
applications appear above it. It requests no keyboard focus and has an empty
pointer input region.

For a beginner-friendly implementation map, diagrams, Zig reading guide, and
future plans, see [Architecture and roadmap](ARCHITECTURE.md).

**Status:** builds with the installed Zig 0.17.0. Unit tests, non-visual CLI
integration tests, synthetic multi-output Wayland discovery tests, and real
output discovery pass. Follow-up authorized desktop tests verified NVDEC decoding,
visible playback (confirmed by the user), and graceful termination. A hidden-surface
render stall was fixed; see the fullscreen-start caveat below. Actual hotplug and
mixed-display rendering still need validation. This is not a completed Wallpaper
Engine port.

## Requirements / build

Linux, Zig **0.17.0**, pkg-config, wayland-scanner, the wayland-protocols data
package, and development headers/libraries for:

- wayland-client and wayland-egl
- EGL and desktop OpenGL
- libmpv
- libavformat, libavcodec, libavutil for the FFmpeg backend (omit with `-Dffmpeg=false`)

These are already installed on the original development machine. No desktop
shell or compositor-specific command/IPC is needed. Runtime wallpaper placement
requires the compositor to advertise **zwlr_layer_shell_v1**. A Wayland session
alone does not guarantee this capability; unsupported compositors produce an
error rather than opening a normal application window.

```sh
zig build -Doptimize=ReleaseSafe
zig build test
python3 tests/cli.py
python3 tests/wayland.py
python3 tests/control.py  # real libmpv + offscreen Mesa; requires cc and ffmpeg
python3 tests/replacement.py  # transactional set-video, both backends; no desktop
python3 tests/ffmpeg.py   # integrated FFmpeg + native YUV shader tests; no CUDA/desktop
python3 tests/install.py  # uses a temporary HOME, never your actual user bin
```

Executable: `zig-out/bin/stillwave`. No package installation or downloads
happen during a build. Standard protocol XMLs default to
`/usr/share/wayland-protocols`; override with
`-Dwayland-protocols=/absolute/path` if necessary. C bindings use
`zig translate-c` because this compiler no longer provides `@cImport`.
Other Zig releases and cross-compilation have not been validated.

## Opt-in FFmpeg backend (same binary)

```sh
./zig-out/bin/stillwave run --backend ffmpeg --profile-startup /path/to/video.mp4 2>stillwave-ffmpeg.log
# In another terminal: ./zig-out/bin/stillwave hide | show | quit
```

mpv remains the default. FFmpeg uses GPU YUV-to-RGB conversion, no CPU RGBA
conversion or CUDA/GL interop, and releases decoder/CUDA and video-texture
resources on hide while retaining EGL setup. It is muted-only and rejects
unsupported native pixel formats/HDR; use mpv for those features. Existing
output/scaling/control behavior is shared. See [FFmpeg backend details](FFMPEG_BACKEND.md)
for build options, formats, nonblocking teardown, tests, and measurement caveats.
NVIDIA performance/VRAM must be measured on the integrated path, not assumed from
the earlier prototype.

## Experimental FFmpeg lifecycle probe

A separate decode-only prototype tests explicit decoder/CUDA-device teardown,
without changing Stillwave or creating desktop surfaces:

```sh
zig build ffmpeg-probe -Doptimize=ReleaseSafe
./zig-out/bin/ffmpeg-probe --decoder software /path/to/video.mp4
```

It starts hidden and accepts `show`, `hide`, and `quit` on stdin. See
[the experiment guide](experiments/README.md) for CUDA mode, VRAM measurements,
timing definitions, and software-only tests. It is not a wallpaper replacement
and is not installed by ordinary builds or `install-system`.

A second opt-in target adds one-output Wayland/OpenGL rendering without mpv:

```sh
zig build ffmpeg-render-probe -Doptimize=ReleaseSafe
./zig-out/bin/ffmpeg-render-probe --decoder cuda /path/to/video.mp4
```

It also starts hidden and accepts `show`, `hide`, `quit` on stdin. See
[rendering experiment instructions](experiments/RENDERING.md) for timing/VRAM
measurements and limitations. These probes retain the original experiment paths;
the integrated FFmpeg backend above uses a different, native-plane GPU renderer.

## User-level installation

```sh
zig build install-system -Doptimize=ReleaseSafe
stillwave --version
```

Despite the step name, this is a **user-level** install: it builds and copies only
`stillwave` to `$HOME/.local/bin/stillwave`, creating the directory if needed and
setting executable permissions (0755). `~/.local/bin` is already on PATH in the
original development machine's `config.fish`; on other machines, add it to your
shell's PATH yourself. No sudo or shell configuration changes are needed here.

This explicit step replaces any existing binary at that destination; run it again
to update or reinstall. It requires an absolute `HOME` and the Linux `install`
utility. `--prefix` still controls ordinary `zig build` installation, but does not
change this step's user-level destination. Ordinary builds do not install to your
PATH. No config files, libraries, desktop settings, or startup services are
installed or changed, and playback is not started.

To uninstall, remove `$HOME/.local/bin/stillwave`; your configuration stays intact.

## Try your video

From this project directory:

```sh
./zig-out/bin/stillwave list-outputs
./zig-out/bin/stillwave run --no-config ./11526981-uhd_3840_2160_30fps.mp4
```

The second command uses defaults on **all connected displays**. Run in the
foreground; **Ctrl-C** or SIGTERM requests shutdown. No login startup or
desktop configuration is installed.

Select a subset using exact names returned by output discovery:

```sh
./zig-out/bin/stillwave run --no-config \
  --output DISPLAY_NAME_1 --output DISPLAY_NAME_2 /path/to/video.mp4
```

Display names, resolutions, aspect ratios, refresh rates, arrangement, positions,
and rotations are not hard-coded. Each output gets its own full-coverage
surface, sized by compositor configure events, not by physical dimensions or
layout coordinates. Integer scale is respected; fractional preferred scale is
used when both fractional-scale and viewporter are advertised. Rotation is
handled by the compositor: buffers use surface-local dimensions.

An empty selection means all outputs, including newly connected ones. An explicit
selection requires those names to exist at startup. Disconnected outputs are
removed; selected names are matched again on reconnection. If no selected
outputs remain, the process waits for reconnection until stopped. A compositor
closing a layer surface on an otherwise connected output is treated as an error.

### Existing wallpaper providers

Background surfaces in the same layer have **no defined relative ordering**.
An existing wallpaper provider may cover this one or vice versa. If a video
doesn't appear, check your other wallpaper provider and manually disable only
its wallpaper feature before retrying. This application never kills a shell,
edits its configuration, or raises the video above application windows.

## Hide, show, and quit from the same binary

Keep one foreground process running:

```sh
# Terminal 1: normal configuration, with optional startup/resume measurements
./zig-out/bin/stillwave run --profile-startup 2>startup.log

# Terminal 2, or event-triggered scripts:
./zig-out/bin/stillwave hide
./zig-out/bin/stillwave show
./zig-out/bin/stillwave quit
```

- `hide` unmaps the wallpaper and stops/unloads playback (not just pauses it).
  This allows media/decoder resources to be released while retaining the player,
  EGL window/context, and (for mpv) its renderer. FFmpeg additionally deletes video
  textures and performs decoder/CUDA teardown off the control thread. Pending
  updates are consumed without drawing or kept in a bounded latest-frame slot.
- `show` remaps the wallpaper and starts the same video **from the beginning**.
  It reloads media in the existing player, retaining expensive graphics resources.
  A fresh configure handshake and new-file playback readiness precede presentation.
  The configured `paused` setting is respected.
- Repeated `hide` or `show` requests are harmless; `show` while visible does not
  restart playback. Rapid requests converge on the latest requested state.
- `quit` requests clean shutdown, including while hidden. Ctrl-C/SIGTERM still work.
- These commands take no settings/arguments, do not load configuration, and fail
  if there is no running instance. They never start a process automatically.

`run` remains foreground-only: no daemon, service, or second executable is
installed. A second `run` in the same user/Wayland session is rejected before
graphics initialization. Use the **new locally built binary for both the owner
and commands**; an older PATH installation does not understand these commands.

Control uses a private Unix datagram socket and advisory lock in
`$XDG_RUNTIME_DIR/stillwave-<session-hash>/`. The runtime directory must be absolute,
owned by this user, and private (normally mode 0700). The Wayland display's
canonical socket path identifies the session; clients must target the same
session. Inherited `WAYLAND_SOCKET` connections are not supported for `run` or
control commands. Socket files are removed on normal exit and recovered after a
crash; a small private directory and lock file remain intentionally.

A successful hide/show/quit command acknowledges the requested state, **not** completion of the
asynchronous playback transition or compositor presentation. Clients wait up to
five seconds for that acknowledgement. No screen-visibility guarantee is made.
Media/decoder allocations can be released on hide, but renderer caches, EGL back
buffers, and driver allocations remain possible. **A particular VRAM reduction
is not guaranteed**; measure on your GPU. Quit destroys the retained resources.
Hotplugged outputs are initialized when next shown; removed outputs still release
their resources. `--no-loop` exits at completion; FFmpeg permits a 500 ms final
presentation grace if the compositor withholds callbacks (see backend details).

The non-desktop lifecycle test uses a fake Wayland server and a test-only EGL
shim with real libmpv and Mesa offscreen rendering. It checks command routing,
remapping, completed hidden unload, presentation inactivity, context retention,
rapid toggles, interrupted loading, delayed terminal events, paused restarts,
EOF behavior, duplicate rejection, and crash recovery. Actual compositor /
NVIDIA remapping and perceived resume latency still require desktop validation.

## Replace the video and save it

```sh
# Owner must use configuration (default XDG or an explicit --config file).
./zig-out/bin/stillwave run /path/to/first.mp4
# Another terminal, using the same locally built binary/session:
./zig-out/bin/stillwave set-video /path/to/next.mp4
# For a filename starting with '-': stillwave set-video -- -clip.mp4
```

`set-video` replaces media on every selected output and explicitly persists only
`media` in **the owner's startup config file**. Relative video paths resolve in
the command caller's working directory and are saved as absolute paths. Other
settings and unrelated config bytes are preserved; CLI overrides are not saved.
A missing config and its parent directories are created. A runner started with
`--no-config` rejects this command. Config symlinks/nonregular files are rejected.

The owner stages muted players on unmapped surfaces, decodes and draws a first
frame offscreen for each selected output, then atomically saves the config and
switches players. Candidates are held paused until commit so short videos do not
finish during validation. The original players remain intact on load/save failure:
no rollback reload is needed. This temporarily requires extra decoder/GPU resources;
there is no crossfade or frame-exact multi-output transition. The existing backend,
scaling, looping, mute and paused settings remain in effect.

Hidden replacements remain hidden, validate offscreen and unload decoding resources;
next show starts the committed video from the beginning. Outputs not yet initialized
use the committed path when initialized. Validation is not a promise that the file
will remain readable or decode forever after commit or a later reload.

One transaction runs at a time; concurrent replacements and hide/show during
validation return a busy error (retry). Quit remains available. Output connection
changes during validation abort the transaction; no selected outputs is an error.
Validation has a 30-second deadline; the client waits up to 60 seconds for the final
result. Success means first-frame validation and saving completed, **not** that the
compositor presented the new video. Decoder resource cleanup may continue afterward,
during which another replacement can still return busy.

Config contents and permissions are checked again before saving; detected edits
abort without changing playback. Atomic rename prevents partial JSON, but does not
serialize against uncooperative editors in the narrow check-to-rename interval.
Avoid editing the same config concurrently with `set-video`. File data is fsynced;
crash/power-loss atomicity across playback and filesystem state is not promised.

## Startup profiling

Use the locally built executable (an existing PATH installation is not updated by
an ordinary build):

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/stillwave run --profile-startup 2>startup.log
# Or add --no-config /path/to/video.mp4 to bypass your usual config.
```

Timings go to stderr even with `--log-level quiet`; stdout stays unchanged.
Each `[startup] +N ms [output] stage (D ms)` line reports monotonic elapsed
wall time since entry to `main` and the duration of that named stage. This
includes blocking/waiting, not just CPU work. It excludes shell and dynamic
loader time before `main`. Failed stages have no completion line.

Milestones cover argument/config loading, media validation, Wayland discovery,
EGL setup, and each output's surface configure, mpv initialization/render
context, worker load request, first FRAME update, first render and first swap.
The load-to-FRAME interval includes decoder/media work and event-loop scheduling;
it is not a pure decoding measurement. Outputs initialize serially, so one
output's work can delay another's configure/frame observation. Durations can
overlap and should not be summed.

The first submitted frame is **not confirmed visible**: swap completion is not
compositor presentation feedback, and a fullscreen window or another wallpaper
provider may hide it. There is no per-frame profiling after the first submission;
new hotplug surfaces get their own startup milestones. Compare several runs with
the same video, outputs, and build mode; label the first run separately because
filesystem and GPU shader caches can change subsequent timings. Ctrl-C stops
playback normally. Without the flag, no timing lines are emitted.

After each hide/show cycle, retained outputs also report
`show to first frame submitted`. **The parenthesized duration is the show
latency** from handling that command, including remapping and media reload;
the `+N ms` prefix is still time since the original process entered `main`.
Client process/IPC startup and actual compositor presentation are not included.

After stopping playback, `playback unloaded (renderer retained)` confirms that
mpv has reached `idle-active` (no file loaded). Its duration is measured from the
worker issuing stop, not from the control client's launch. Wait for this marker
before sampling hidden VRAM. It confirms playback unloading, **not** that the GPU
driver has returned a specific amount of memory. Compare visible, unloaded-hidden,
and post-quit memory, along with the show latency.

## JSON configuration

Default file:

- `$XDG_CONFIG_HOME/stillwave/config.json` when XDG_CONFIG_HOME is absolute
- otherwise `$HOME/.config/stillwave/config.json`

Unset, empty, or relative XDG_CONFIG_HOME uses the fallback. Without a usable
HOME/XDG base, use `--config /path/to/config.json` or `--no-config`.

A config file is **optional**; no directories/files are created implicitly.
A missing implicit file means defaults. A missing explicit file, malformed
JSON, unknown/duplicate keys, wrong types, invalid enum values, or unsupported
schema versions is an error. Files must be regular files, at most 1 MiB.

Precedence: **built-in defaults < JSON file < explicit CLI overrides**.
Every application setting is serializable using the shared typed settings
model. No hidden mpv config/scripts or shell expansion is loaded.

Complete defaults (also in `examples/config.json`):

```json
{
  "schema_version": 1,
  "backend": "mpv",
  "media": null,
  "outputs": [],
  "scale": "fill",
  "loop": true,
  "mute": true,
  "hwdec": "auto",
  "paused": false,
  "log_level": "info"
}
```

Omitted fields use defaults. `media: null` is a valid template, but playback
requires a readable regular local file. Relative media paths in JSON are resolved
against the config file's directory; CLI video paths are relative to the current
directory. Paths are passed directly to the selected backend, never through a shell. There is
no implicit `~` or environment-variable expansion inside JSON.

| Setting | Values / meaning |
| --- | --- |
| `schema_version` | `1` (also assumed when omitted) |
| `backend` | `mpv` (default) or `ffmpeg` (opt-in, muted-only) |
| `media` | Local video path or `null` |
| `outputs` | Array of unique names; `[]` means all |
| `scale` | `fill` crops preserving aspect; `fit` letterboxes in black |
| `loop` | `true` loops; `false` exits when all current players reach EOF |
| `mute` | `true` disables audio; `false` makes one mpv player audible (unsupported in FFmpeg) |
| `hwdec` | `auto`: mpv auto-safe or FFmpeg CUDA with early software fallback; `no`: software decoding |
| `paused` | Start paused; no runtime resume command in this POC |
| `log_level` | `quiet`, `error`, `warn`, `info`, `debug` |

`config.schema.json` describes this format. Defaults/example/schema agreement is
tested. A JSON Schema validator is not required at runtime.

```sh
# Print a template (redirect to a NEW file of your choice if desired).
./zig-out/bin/stillwave config defaults

# Inspect fully merged settings, without Wayland or playback.
./zig-out/bin/stillwave config show --config /path/to/config.json

# Check structure/values without loading media or connecting to Wayland.
./zig-out/bin/stillwave config validate --config /path/to/config.json

# Override a file's outputs back to all, or override booleans explicitly.
./zig-out/bin/stillwave run --all-outputs --no-loop --mute
```

`config show` accepts the same setting overrides as `run` and prints normalized
JSON with absolute media paths. `config validate` distinguishes a template from
a config with media, but does **not** verify file existence or codec support;
`run` checks file readability and the selected backend checks decoding/features.

Use `--help` for all flags. Options use separate values (`--hwdec no`, not
`--hwdec=no`). Contradictory/repeated setting flags are rejected.
`list-outputs --json` is suitable for scripts; it reports physical current-mode
metadata, not the surface's configured logical/render dimensions.
JSON/stdout is separated from diagnostics/stderr. Exit codes: **0** normal
completion/help/validation/requested shutdown, **2** invalid input/configuration
or unsupported required protocol/selection, **1** runtime/system failure.

## Architecture / limits

- `src/config.zig`, `src/xdg.zig`: shared typed settings, JSON and path rules.
- `src/cli.zig`, `src/main.zig`: CLI commands and overrides.
- `src/app.zig`: lifecycle, per-output resource ownership, poll loop and shutdown.
- `src/platform/wayland.zig`: capability discovery, outputs, layer surfaces,
  configure acknowledgments, input transparency, scaling and frame callbacks.
- `src/render/egl.zig`: EGL/OpenGL presentation.
- `src/render/pacing.zig`: per-output presentation/skip state and regression tests.
- `src/backend.zig`: backend-neutral playback adapter; `src/ffmpeg.zig`,
  `src/ffmpeg_decoder.c`, `src/render/yuv.c`: direct decoding/native YUV GPU rendering.
- `src/player.zig`: libmpv options/rendering, per-player event thread, atomics
  and eventfd wakeups. Render callbacks never invoke Wayland/GL/libmpv.

There is one independent decoder/player per output. Videos repeat separately
on each display (not spanned over the layout); **frame-exact synchronization
across displays is not promised**. New/reconnected displays start at the beginning.
This keeps the POC simple but increases GPU/memory use with additional outputs.
Each mpv player owns an isolated EGL/OpenGL context, made current on the
appropriate window before use. This prevents GL state/resource lifecycle
interference during staged replacement; the context is retained across hide/show.
FFmpeg uses the application's shared context. mpv control operations run on event
threads or use explicitly render-thread-safe async APIs. Wayland and GL objects
are manipulated only on the main/render thread.

Updates and compositor frame callbacks drive drawing; unchanged paused frames
are not continuously rendered. When a compositor withholds frame callbacks for a
hidden surface, new libmpv frames are consumed using `SKIP_RENDERING` rather than
blocking its render API or continuously swapping hidden buffers. The latest
skipped frame is redrawn once callbacks resume. Initial mapping waits for the
first libmpv FRAME update rather than submitting an empty startup frame. This is **not automatic occlusion/fullscreen
pause**: decoding can continue behind windows, and generic Wayland doesn't
reliably expose such state. Display power management/suspend behavior is not yet
validated. No universal zero-copy/hardware-decoding or seamless-loop guarantee.

No GUI, config hot reload, per-output videos/settings, Workshop
downloads, Wallpaper Engine scene/web support, or X11 backend yet. Those can be
added on top of the shared settings/application modules. Before distributing
binaries, review your linked libmpv/FFmpeg build's licensing. Vendored protocol
provenance/license is documented in `protocols/README.md`.

## First-run validation / troubleshooting

**Fullscreen-start caveat on Hyprland 0.57.0:** a background surface first mapped
while an application is fullscreen was observed at compositor opacity 0, remaining
invisible even after leaving fullscreen. This is distinct from the app's fixed
frame-consumption stall. Workaround: **exit fullscreen before starting the
wallpaper**, then minimize/move the terminal or expose an empty workspace to view
it. If already affected, stop with Ctrl-C and restart after exiting fullscreen.
Normal fullscreen coverage is expected; the wallpaper must never appear above a
fullscreen application. No compositor-specific opacity/layer overrides are
implemented, and desktop settings are never changed automatically.

For diagnostics use `--log-level debug`: initial libmpv update/presentation/skip
messages identify frame progress. A fully opaque competing wallpaper provider
can also hide this surface independently of fullscreen state.

1. Run the supplied video. Confirm that apps/panels stay above it and retain
   pointer/keyboard interaction. Check orientation, crop/fit and muted audio.
2. Stop with Ctrl-C; confirm the surface disappears.
3. If GPU decoding/presentation fails, retry `--hwdec no --log-level debug`
   and retain stderr. Info logs report configured dimensions and actual decoder.
4. Test mixed-scale/rotated outputs and disconnect/reconnect on your compositor.
5. Avoid running multiple instances/providers on the same outputs; this POC
   has no single-instance locking.
