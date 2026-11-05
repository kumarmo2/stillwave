#!/bin/sh
# Called by zig build install-system; no shell configuration or startup changes.
set -eu

case "${HOME:-}" in
    /*) ;;
    *) printf "%s\n" "install-system requires an absolute HOME directory" >&2; exit 1 ;;
esac

exec install -Dm755 -- "$1" "$HOME/.local/bin/stillwave"
