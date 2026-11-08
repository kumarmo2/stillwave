# Stillwave

Stillwave plays local videos as animated wallpapers on Linux Wayland desktops.
It is a command-line application written in Zig, using Wayland layer-shell,
EGL/OpenGL, and libmpv by default. Wallpaper surfaces stay behind ordinary
windows and do not receive keyboard or pointer input.

Stillwave can play on all connected displays or a selected subset, loop videos,
choose fill or fit scaling, and change the video while it is running. Each display
plays independently; playback is not synchronized across displays.

## Requirements

- Linux and a Wayland compositor that supports `zwlr_layer_shell_v1`. Not all
  Wayland compositors provide this protocol.
- Zig **0.17.0**, `pkg-config`, `wayland-scanner`, and the wayland-protocols data package.
- Development headers and libraries for Wayland client, Wayland EGL, EGL, desktop
  OpenGL, and libmpv.
- For the optional FFmpeg playback backend: development headers and libraries for
  libavformat, libavcodec, and libavutil.

## Build and install

From the project directory:

```sh
zig build -Doptimize=ReleaseSafe
```

The executable is `./zig-out/bin/stillwave`. To build without the FFmpeg backend
and its development dependencies, add `-Dffmpeg=false`. The build expects
wayland-protocols in `/usr/share/wayland-protocols`; override it with
`-Dwayland-protocols=/path/to/wayland-protocols` if needed.

To install the binary for the current user:

```sh
zig build install-system -Doptimize=ReleaseSafe
stillwave --version
```

Despite the step name, this installs only to `$HOME/.local/bin/stillwave` and
replaces an existing binary at that path. Ensure `$HOME/.local/bin` is on your
`PATH`. Re-run the install step after rebuilding to update the installed binary.
To uninstall, remove that file; your configuration is left untouched. Installation
does not start playback or configure automatic startup.

The examples below use `stillwave` from `PATH`. If you have not installed it,
use `./zig-out/bin/stillwave` instead.

## Quick start

```sh
# See the names of connected displays.
stillwave list-outputs

# Play a local video on all displays, without reading a config file.
stillwave run --no-config /path/to/video.mp4
```

The video loops, fills each display, and is muted by default. `run` stays in the
foreground; press **Ctrl-C** to stop it. Stillwave does not install a service or
start automatically when you log in.

To play only on specific displays, use names from `list-outputs`:

```sh
stillwave run --output DISPLAY_NAME_1 --output DISPLAY_NAME_2 /path/to/video.mp4
```

Without an explicit selection, Stillwave uses all outputs, including newly
connected ones. Selected outputs must be connected at startup; if one disconnects,
it is matched again by name when reconnected. Use `--all-outputs` to override a
configured selection.

Useful playback options include:

```sh
stillwave run --scale fit /path/to/video.mp4   # letterbox instead of cropping
stillwave run --no-mute /path/to/video.mp4     # audio on one display (mpv only)
stillwave run --no-loop /path/to/video.mp4     # exit after playback ends
stillwave run --hwdec no /path/to/video.mp4     # use software decoding
```

Run `stillwave --help` for all options. Use `--` before a path that starts with
`-`, and pass option values separately, for example `--scale fit`.

## Control a running wallpaper

In another terminal in the same user and Wayland session:

```sh
stillwave hide
stillwave show
stillwave quit
```

`hide` unmaps the wallpaper and unloads playback; `show` displays it again from
the beginning. Repeated hide or show commands are harmless. `quit` stops the
running instance. These commands do not start Stillwave automatically. One
`run` instance is allowed per user and Wayland session.

Control commands require a private, absolute `$XDG_RUNTIME_DIR` owned by the
current user. They must use the same Wayland session as the running instance;
inherited `WAYLAND_SOCKET` connections are not supported. A successful hide or
show acknowledges the request, not that the compositor has presented a frame.

### Change the video

```sh
# Start with configuration enabled (the default).
stillwave run /path/to/first.mp4

# In another terminal:
stillwave set-video /path/to/next.mp4
```

`set-video` changes the video on all selected displays and saves its absolute path
as `media` in the running instance's config file. Other settings are preserved.
Relative paths are resolved from the command's working directory. If the config
does not exist, Stillwave creates it and its parent directories. This command is
unavailable if `run` was started with `--no-config`; config symlinks and
non-regular files are also rejected.

Stillwave validates the new video before switching. If validation or saving
fails, the existing video remains in use. A hidden wallpaper stays hidden after
the change; the new video starts when shown. Validation temporarily uses additional
decoder and GPU resources. It can fail if no selected displays are connected or
if displays change during validation. Only one replacement can run at a time;
retry if a command reports that replacement or cleanup is busy. Avoid editing the
same config concurrently with `set-video`.

Success means the video was validated and saved, not that the compositor has
presented it. There is no crossfade or frame-exact transition between displays.

## Configuration

The optional JSON configuration file is located at:

- `$XDG_CONFIG_HOME/stillwave/config.json`, if `XDG_CONFIG_HOME` is absolute; or
- `$HOME/.config/stillwave/config.json` otherwise.

Use `--config /path/to/config.json` to select an existing file, or `--no-config`
to ignore configuration. An absent default config uses built-in defaults. Settings
are applied in this order: **defaults < config file < command-line overrides**.
A normal `run` does not write a config; `set-video` explicitly updates `media`.

Example:

```json
{
  "schema_version": 1,
  "media": "/home/user/Videos/wallpaper.mp4",
  "outputs": [],
  "scale": "fill",
  "loop": true,
  "mute": true,
  "hwdec": "auto"
}
```

Omitted fields use defaults. `outputs: []` selects all displays. Relative `media`
paths in JSON are resolved relative to the config file; command-line paths are
relative to the caller's working directory. JSON paths do not expand `~` or
environment variables.

| Setting | Default | Description |
| --- | --- | --- |
| `schema_version` | `1` | Configuration format version. |
| `backend` | `"mpv"` | `"mpv"` or `"ffmpeg"`. |
| `media` | `null` | Readable local video path; required for playback unless supplied on the command line. |
| `outputs` | `[]` | Display names; an empty array selects all outputs. |
| `scale` | `"fill"` | `"fill"` crops to cover; `"fit"` preserves the entire video with letterboxing. |
| `loop` | `true` | Repeat the video; when false, exit after playback finishes. |
| `mute` | `true` | Disable audio; when false, one mpv player is audible. |
| `hwdec` | `"auto"` | Attempt hardware decoding; use `"no"` for software decoding. |
| `paused` | `false` | Start paused. There is currently no runtime resume command. |
| `log_level` | `"info"` | `"quiet"`, `"error"`, `"warn"`, `"info"`, or `"debug"`. |

```sh
stillwave config defaults                         # print the default template
stillwave config show                             # show merged settings
stillwave config validate --config /path/to/config.json
```

`config validate` checks the configuration format and values, but does not check
whether the video exists or can be decoded. See [the example config](examples/config.json)
and [JSON schema](config.schema.json) for the complete format.

## Playback backends

The default **mpv** backend supports audio and uses libmpv for playback. The
optional **FFmpeg** backend is muted-only:

```sh
stillwave run --backend ffmpeg /path/to/video.mp4
```

The FFmpeg backend supports a limited set of pixel formats and does not support
HDR tone mapping. With `--hwdec auto`, it attempts CUDA when available and may
fall back to software decoding before playback starts. Use mpv if you need audio
or unsupported formats. See [FFmpeg backend details](FFMPEG_BACKEND.md) for
formats and implementation details.

## Troubleshooting and limitations

- **No wallpaper appears:** make sure your compositor supports layer-shell and
  that another wallpaper provider is not covering Stillwave. Background surfaces
  in the same layer have no guaranteed ordering.
- **Starting under fullscreen:** on Hyprland 0.57.0, a wallpaper started while an
  application is fullscreen may remain invisible. Exit fullscreen before starting
  Stillwave; if necessary, stop and restart it.
- **Video or hardware decoding fails:** try `--hwdec no --log-level debug`.
- **Changes to the binary are not reflected:** an ordinary build does not update
  the installed binary. Re-run `zig build install-system` or use the local binary
  for both the running instance and control commands.

Stillwave plays local video files; it does not provide a GUI, X11 backend,
Wallpaper Engine scene/web playback, or per-display videos. Covering the
wallpaper with another window does not automatically pause decoding. Hiding
unloads playback but does not guarantee a particular reduction in GPU memory.

## More information

- [Architecture and implementation](ARCHITECTURE.md)
- [FFmpeg backend](FFMPEG_BACKEND.md)
- [Protocol provenance and licensing](protocols/README.md)
