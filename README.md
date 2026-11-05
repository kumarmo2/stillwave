# Stillwave (proof of concept)

CLI-only local video wallpapers, implemented in Zig using Wayland layer-shell,
EGL/OpenGL, and libmpv. A wallpaper uses the **background** layer: ordinary
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
python3 tests/install.py  # uses a temporary HOME, never your actual user bin
```

Executable: `zig-out/bin/stillwave`. No package installation or downloads
happen during a build. Standard protocol XMLs default to
`/usr/share/wayland-protocols`; override with
`-Dwayland-protocols=/absolute/path` if necessary. C bindings use
`zig translate-c` because this compiler no longer provides `@cImport`.
Other Zig releases and cross-compilation have not been validated.

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
directory. Paths are passed directly to libmpv, never through a shell. There is
no implicit `~` or environment-variable expansion inside JSON.

| Setting | Values / meaning |
| --- | --- |
| `schema_version` | `1` (also assumed when omitted) |
| `media` | Local video path or `null` |
| `outputs` | Array of unique names; `[]` means all |
| `scale` | `fill` crops preserving aspect; `fit` letterboxes in black |
| `loop` | `true` loops; `false` exits when all current players reach EOF |
| `mute` | `true` disables audio; `false` makes only one output's player audible |
| `hwdec` | `auto` uses libmpv auto-safe with software fallback; `no` disables |
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
`run` checks file readability and libmpv checks decoding.

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
- `src/player.zig`: libmpv options/rendering, per-player event thread, atomics
  and eventfd wakeups. Render callbacks never invoke Wayland/GL/libmpv.

There is one independent decoder/player per output. Videos repeat separately
on each display (not spanned over the layout); **frame-exact synchronization
across displays is not promised**. New/reconnected displays start at the beginning.
This keeps the POC simple but increases GPU/memory use with additional outputs.
Player render contexts share the render-owner EGL context and are made current
on the appropriate window before use; mpv control operations run on event
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

No GUI, control socket, config hot reload, per-output videos/settings, Workshop
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
