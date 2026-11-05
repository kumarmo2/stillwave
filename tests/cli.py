#!/usr/bin/env python3
"""Non-visual integration tests. Never creates a wallpaper surface."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/stillwave").resolve()
root = Path(__file__).resolve().parents[1]
checks = 0

with tempfile.TemporaryDirectory(prefix="stillwave-test-") as tmp:
    base = Path(tmp)
    home = base / "home"
    home.mkdir()
    env = os.environ | {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(base / "config"),
        "WAYLAND_DISPLAY": str(base / "not-a-wayland-socket"),
    }
    def run(*args, status=0, overrides=None, cwd=base):
        global checks
        result = subprocess.run([str(binary), *args], env=env | (overrides or {}),
                                cwd=cwd, capture_output=True, text=True, timeout=10)
        assert result.returncode == status, (args, result.returncode, result.stderr)
        if status:
            assert not result.stdout, (args, result.stdout)
            assert result.stderr.startswith("stillwave:"), result.stderr
        checks += 1
        return result

    help_text = run("--help").stdout
    assert "Usage:" in help_text and "stillwave run" in help_text
    assert "$XDG_CONFIG_HOME/stillwave/config.json" in help_text
    version = run("--version").stdout
    assert version.startswith("stillwave ") and "poc" in version
    defaults = json.loads(run("config", "defaults").stdout)
    assert defaults == json.loads((root / "examples/config.json").read_text())
    schema = json.loads((root / "config.schema.json").read_text())
    assert defaults == {key: value["default"] for key, value in schema["properties"].items()}
    try:
        import jsonschema
    except ImportError:
        pass
    else:
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.validate(defaults, schema)
    assert json.loads(run("config", "show").stdout) == defaults
    assert not (base / "config").exists(), "reading defaults created a config directory"

    cfg_dir = base / "config" / "stillwave"
    cfg_dir.mkdir(parents=True)
    cfg_path = cfg_dir / "config.json"
    cfg_path.write_text(json.dumps({"media": "clips/with space.mp4", "outputs": ["left", "portrait"], "mute": False, "loop": False}))
    effective = json.loads(run("config", "show").stdout)
    assert effective["media"] == str(cfg_dir / "clips/with space.mp4")
    assert effective["outputs"] == ["left", "portrait"]
    assert effective["mute"] is False and effective["loop"] is False
    override = json.loads(run("config", "show", "--mute", "--loop", "--all-outputs", "cli.mp4").stdout)
    assert override["mute"] is True and override["loop"] is True and override["outputs"] == []
    assert override["media"] == str(base / "cli.mp4")
    selected = json.loads(run("config", "show", "--output", "A", "--output", "B").stdout)
    assert selected["outputs"] == ["A", "B"]
    assert json.loads(run("config", "show", "--no-config").stdout) == defaults
    assert json.loads(run("config", "show", "--no-config", "--", "-clip.mp4").stdout)["media"] == str(base / "-clip.mp4")
    assert json.loads(run("config", "show", "--config", str(cfg_path)).stdout) == effective
    run("config", "show", "--config", "missing.json", status=2)
    run("run", "--no-config", status=2)
    run("run", "--no-config", "missing.mp4", status=2)
    run("run", "--no-config", str(base), status=2)
    run("run", "--no-config", "--output", "A", "--output", "A", "missing.mp4", status=2)
    run("run", "--mute", "--no-mute", status=2)
    run("run", "--config", "x", "--no-config", status=2)
    run("run", "--output", "A", "--all-outputs", status=2)
    run("run", "--hwdec", "unsupported", status=2)
    run("config", "show", "--garbage", "x", status=2)
    run("list-outputs", "--config", "x", status=2)

    # No playback is started: run rejects media before connecting to Wayland.
    fake_video = base / "exists.mp4"
    fake_video.write_bytes(b"not really a video")
    assert "WaylandConnectionFailed" in run("run", "--no-config", str(fake_video), status=1).stderr

    for invalid in ['[]', '{', '{"mute":null}', '{"schema_version":2}',
                    '{"mute":true,"mute":false}', '{"extra":1}',
                    '{"outputs":["same","same"]}', '{"outputs":null}',
                    '{"media":""}', '{"media":"a\\u0000b"}']:
        cfg_path.write_text(invalid)
        run("config", "show", status=2)
    # Help/defaults must not load a broken config.
    run("--help")
    run("--version")
    run("config", "defaults")

    cfg_path.write_text("{}")
    assert "template" in run("config", "validate").stdout
    before = cfg_path.read_bytes()
    run("config", "show", "--no-loop")
    assert cfg_path.read_bytes() == before
    os.chmod(cfg_path, 0)
    try:
        if os.geteuid() != 0:
            run("config", "show", status=2)
    finally:
        os.chmod(cfg_path, 0o600)
    cfg_path.unlink()
    cfg_path.mkdir()
    run("config", "show", status=2)
    cfg_path.rmdir()
    os.mkfifo(cfg_path)
    run("config", "show", status=2)
    cfg_path.unlink()
    cfg_path.write_bytes(b" " * (1024 * 1024 + 1))
    run("config", "show", status=2)

    fallback = home / ".config" / "stillwave"
    fallback.mkdir(parents=True)
    (fallback / "config.json").write_text('{"scale":"fit"}')
    for value in ("", "relative"):
        assert json.loads(run("config", "show", overrides={"XDG_CONFIG_HOME": value}).stdout)["scale"] == "fit"
    run("config", "show", overrides={"XDG_CONFIG_HOME": "", "HOME": ""}, status=2)
    run("config", "show", "--no-config", overrides={"XDG_CONFIG_HOME": "", "HOME": ""})

print(f"{checks} non-visual CLI checks passed")
