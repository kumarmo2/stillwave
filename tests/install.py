#!/usr/bin/env python3
"""Build/install checks confined to a temporary HOME; never starts playback."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
zig = shutil.which(sys.argv[1] if len(sys.argv) > 1 else "zig")
assert zig, "zig not found; pass its executable path as the first argument"
checks = 0
# Keep the normal Linux compiler cache when HOME changes; installation stays isolated.
cache_base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
global_cache = os.environ.get("ZIG_GLOBAL_CACHE_DIR") or str(cache_base / "zig")

with tempfile.TemporaryDirectory(prefix="stillwave-install-test-") as tmp:
    base = Path(tmp)
    home = base / "home with spaces"
    destination = home / ".local" / "bin" / "stillwave"
    env = os.environ | {"HOME": str(home), "ZIG_GLOBAL_CACHE_DIR": global_cache}

    def build(*args, environment=env, succeeds=True):
        global checks
        result = subprocess.run([zig, "build", *args], cwd=root, env=environment,
                                capture_output=True, text=True, timeout=120)
        assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
        checks += 1
        return result

    # The ordinary default install remains under --prefix, not in the user's PATH.
    prefix = base / "build output"
    build("-Doptimize=ReleaseSafe", "--prefix", str(prefix))
    artifact = prefix / "bin" / "stillwave"
    assert artifact.is_file()
    assert not destination.parent.exists(), "ordinary build installed to the user bin"

    ignored_prefix = base / "ignored prefix"
    build("install-system", "-Doptimize=ReleaseSafe", "--prefix", str(ignored_prefix))
    assert not ignored_prefix.exists(), "install-system unexpectedly used --prefix"
    assert destination.is_file()
    assert stat.S_IMODE(destination.stat().st_mode) == 0o755
    assert destination.read_bytes() == artifact.read_bytes()
    result = subprocess.run([str(destination), "--version"], env=env,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stdout.startswith("stillwave "), result
    checks += 1

    # The installer must rerun even when the compiled artifact is cached.
    destination.write_bytes(b"outdated installation")
    build("install-system", "-Doptimize=ReleaseSafe")
    assert destination.read_bytes() == artifact.read_bytes()
    destination.unlink()
    build("install-system", "-Doptimize=ReleaseSafe")
    assert destination.read_bytes() == artifact.read_bytes()
    assert not (home / ".config").exists(), "install created configuration"

    # A cached build configuration must not retain a previous invocation\'s HOME.
    another_home = base / "another home"
    build("install-system", "-Doptimize=ReleaseSafe", environment=env | {"HOME": str(another_home)})
    assert (another_home / ".local" / "bin" / "stillwave").read_bytes() == artifact.read_bytes()

    no_home = env.copy()
    no_home.pop("HOME")
    assert "install-system" in build("--help", environment=no_home).stdout
    for environment in (no_home, env | {"HOME": ""},
                        env | {"HOME": os.path.relpath(base / "relative home", root)}):
        result = build("install-system", environment=environment, succeeds=False)
        assert "install-system requires an absolute HOME directory" in result.stderr
    assert not (base / "relative home").exists()

print(f"{checks} isolated build/install checks passed (temporary HOME only)")
