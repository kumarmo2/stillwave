# Protocol sources

`wlr-layer-shell-unstable-v1.xml` is an unchanged upstream copy from
[swaywm/wlr-protocols](https://github.com/swaywm/wlr-protocols), pinned to commit
`b010a03648b88d143236de193bddbfea0c08bc84`:

https://raw.githubusercontent.com/swaywm/wlr-protocols/b010a03648b88d143236de193bddbfea0c08bc84/unstable/wlr-layer-shell-unstable-v1.xml

The file carries its original permissive copyright/license notice.

Standard xdg-shell, xdg-output, viewporter, and fractional-scale XMLs come from
the installed wayland-protocols development package. Override its data directory
with `zig build -Dwayland-protocols=/path/to/wayland-protocols`.
Generated C/headers and Zig bindings live only in the build cache.
No protocol files are fetched during a build.
