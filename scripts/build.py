#!/usr/bin/env python3
"""Build your installed, supported Steam game into a fresh unsigned iPad app.

Run `python3 scripts/build.py doctor`, `check`, or `build` from any directory.
Only public GL4ES source and missing build tools may be downloaded. Your game
and Steam binaries are read from your Mac; all generated files stay in work/.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "kit"
WORK = ROOT / "work"
TOOLS = KIT / "tools"
sys.path.insert(0, str(TOOLS))
import portkit
import build_gl4es
import audit_game
import stage_steam_client

GAME_PROFILE = KIT / "profiles/local-inputs-v2.json"
STEAM_PROFILE = KIT / "evidence/steam-engine-feasibility.json"
GAME_SURVEY = KIT / "evidence/ipad-runtime-survey.json"
STEAM_SURVEY = KIT / "evidence/steam-runtime-survey-001.json"


class BuildError(RuntimeError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text())


def status(message):
    print(message, file=sys.stderr, flush=True)


def capture(argv, env=None):
    return subprocess.check_output(list(map(str, argv)), text=True, env=env,
                                   stderr=subprocess.STDOUT).strip()


def steam_libraries(home=None):
    """Read library locations and game manifests, never account configuration."""
    home = Path.home() if home is None else Path(home)
    primary = home / "Library/Application Support/Steam"
    libraries = [primary]
    for vdf in (primary / "steamapps/libraryfolders.vdf", primary / "config/libraryfolders.vdf"):
        if not vdf.is_file():
            continue
        parsed = audit_game.parse_vdf(vdf.read_text())
        folders = parsed.get("libraryfolders", parsed.get("LibraryFolders", {}))
        for key, entry in folders.items():
            location = entry.get("path") if isinstance(entry, dict) else entry if str(key).isdigit() else None
            if location:
                libraries.append(Path(location).expanduser())
    return list(dict.fromkeys(path.resolve() for path in libraries))


def discover_game(libraries):
    candidates = []
    for library in libraries:
        manifest = library / "steamapps/appmanifest_3009300.acf"
        if not manifest.is_file():
            continue
        state = audit_game.parse_vdf(manifest.read_text()).get("AppState", {})
        directory = state.get("installdir")
        if state.get("appid") != portkit.APP_ID or not directory:
            continue
        relative = Path(directory)
        if relative.is_absolute() or ".." in relative.parts:
            raise BuildError("Steam game manifest contains an invalid installation directory")
        installed = library / "steamapps/common" / relative
        for app in (installed / "TeamfightManager2.app", *sorted(installed.glob("*.app"))):
            if app.is_dir() and app.resolve() not in candidates:
                candidates.append(app.resolve())
    if len(candidates) > 1:
        raise BuildError("Multiple game installations found; select one with --app")
    return candidates[0] if candidates else None


def discover_steam(libraries):
    for library in libraries:
        for candidate in (library / "Steam.AppBundle/Steam/Contents",
                          library / "Steam.AppBundle/Contents"):
            if all((candidate / name).is_file() for name in stage_steam_client.ALLOWLIST):
                return candidate.resolve()
    return None


def source_paths(args):
    libraries = steam_libraries()
    app = args.app.expanduser().resolve() if args.app else discover_game(libraries)
    steam = args.steam_contents.expanduser().resolve() if args.steam_contents else discover_steam(libraries)
    return app, steam


def checked_inputs(app, steam):
    if app is None:
        raise BuildError("Teamfight Manager 2 not found. Install the Mac Steam version or pass --app /path/TeamfightManager2.app")
    current = portkit.observe(app)
    changes = portkit.differences(read_json(GAME_PROFILE), current)
    if changes:
        raise BuildError("Unsupported or changed game input: " + ", ".join(changes) + ". Use the supported Steam build documented in docs/compatibility.md; input pins are never updated automatically.")
    if steam is None:
        raise BuildError("Installed Mac Steam client not found; pass --steam-contents /path/to/Steam.AppBundle/Steam/Contents")
    records = {item["path"]: item for item in read_json(STEAM_PROFILE)["installed_client"]["images"]}
    if set(records) != set(stage_steam_client.ALLOWLIST):
        raise BuildError("Steam input profile has an unexpected binary allowlist")
    for relative, record in records.items():
        path = steam / relative
        if not path.is_file() or not path.resolve().is_relative_to(steam):
            raise BuildError("Missing Steam binary: " + relative)
        if path.stat().st_size != record["size"] or portkit.sha256(path) != record["sha256"]:
            raise BuildError("Unsupported or changed Steam binary: " + relative + ". See docs/compatibility.md; unknown client versions are never approved automatically.")
    for alias, canonical in stage_steam_client.PATH_ALIASES.items():
        path = steam / alias
        if not path.is_file() or not path.resolve().is_relative_to(steam) or portkit.sha256(path) != records[canonical]["sha256"]:
            raise BuildError("Steam dependency alias differs from the reviewed input: " + alias)
    if portkit.sha256(KIT / "vendor/agepad/prepare-de-load-image.py") != portkit.ADAPTER_SHA256:
        raise BuildError("Vendored AgePad adapter differs from its pinned digest")
    for path in (GAME_SURVEY, STEAM_SURVEY):
        if not path.is_file() or read_json(path).get("status") != "complete":
            raise BuildError("Required reviewed runtime survey missing or incomplete: " + str(path))
    return {"status": "supported_local_inputs", "game": str(app), "steam_contents": str(steam),
            "game_version": current["bundle_version"], "steam_build_id": current["steam_build_id"],
            "game_input_hashes": current["files"], "steam_binary_count": len(records),
            "server_latest_checked": False, "account_files_read": False}


def developer_environment():
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    if not env.get("DEVELOPER_DIR"):
        try:
            env["DEVELOPER_DIR"] = capture(["xcode-select", "-p"])
        except (OSError, subprocess.SubprocessError) as error:
            raise BuildError("Select a full Xcode installation with xcode-select or DEVELOPER_DIR") from error
        # Command Line Tools often remain selected after Xcode is installed.
        # Prefer the conventional full installation without changing system settings.
        if not (Path(env["DEVELOPER_DIR"]) / "Platforms/iPhoneOS.platform").is_dir():
            conventional = Path("/Applications/Xcode.app/Contents/Developer")
            alternatives = sorted(Path("/Applications").glob("Xcode*.app/Contents/Developer"))
            candidates = [conventional, *alternatives]
            selected = next((path for path in candidates if (path / "Platforms/iPhoneOS.platform").is_dir()), None)
            if selected:
                env["DEVELOPER_DIR"] = str(selected)
    return env


def doctor(args):
    checks = {"macos": sys.platform == "darwin", "python_3_11_or_newer": sys.version_info >= (3, 11)}
    report = {"status": "environment_check", "host": platform.machine(), "checks": checks,
              "tools": {name: shutil.which(name) for name in ("git", "cmake", "ninja", "xcrun", "codesign", "iconutil")},
              "missing_cmake_ninja": "build automatically bootstraps missing cmake/ninja under work/cache/tools unless --offline"}
    report["free_disk_bytes"] = shutil.disk_usage(ROOT).free
    try:
        env = developer_environment()
        report["developer_dir"] = env["DEVELOPER_DIR"]
        report["iphoneos_sdk"] = capture(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env)
        checks["iphoneos_sdk"] = Path(report["iphoneos_sdk"]).is_dir()
        for name in ("clang", "actool", "otool", "nm", "lipo"):
            capture(["xcrun", "--find", name], env)
        checks["xcode_tools"] = True
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        checks["iphoneos_sdk"] = False
        report["xcode_error"] = str(error)
    try:
        app, steam = source_paths(args)
        report["game"] = str(app) if app else None
        report["steam_contents"] = str(steam) if steam else None
        checks["game_found"] = app is not None and app.is_dir()
        checks["steam_client_found"] = steam is not None and steam.is_dir()
    except (BuildError, OSError, ValueError) as error:
        checks["source_discovery"] = False
        report["source_error"] = str(error)
    for name in ("git", "xcrun", "codesign", "iconutil"):
        checks[name] = bool(report["tools"][name])
    report["ok"] = all(checks.values())
    report["next"] = "python3 scripts/build.py check"
    return report


def bootstrap_tools(env, offline):
    missing = [name for name in ("cmake", "ninja") if not shutil.which(name, path=env.get("PATH"))]
    if not missing:
        return env
    environment = WORK / "cache/tools"
    executables = environment / "bin"
    updated = dict(env, PATH=str(executables) + os.pathsep + env.get("PATH", ""))
    if all(shutil.which(name, path=updated["PATH"]) for name in missing):
        return updated
    if offline:
        raise BuildError("Missing build tools in offline mode: " + ", ".join(missing) + ". Install cmake and ninja or run once without --offline.")
    status("Preparing missing build tools in work/cache/tools…")
    subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True, env=env)
    subprocess.run([str(executables / "python3"), "-m", "pip", "install", "--disable-pip-version-check",
                    "--retries", "3", "--timeout", "30", "cmake==3.31.6", "ninja==1.11.1.4"],
                   check=True, env=env, stdout=sys.stderr, stderr=sys.stderr)
    return updated


def run_step(report, output, env, name, argv, timeout=None):
    status("Building: " + name)
    log = output / (name + ".log")
    entry = {"name": name, "argv": list(map(str, argv)), "log": str(log.relative_to(output))}
    report["steps"].append(entry)
    try:
        with log.open("wb") as stream:
            result = subprocess.run(entry["argv"], env=env, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        entry["timed_out_seconds"] = timeout
        (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
        raise BuildError(f"{name} timed out after {timeout} seconds; see {log}") from error
    entry["exit_code"] = result.returncode
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    if result.returncode:
        tail = "\n".join(log.read_text(errors="replace").splitlines()[-12:])
        raise BuildError(f"{name} failed ({result.returncode}); see {log}\n{tail}")


def gl4es_source(args, env, report, output):
    source = args.gl4es_source.expanduser().resolve() if args.gl4es_source else WORK / "cache" / ("gl4es-" + build_gl4es.COMMIT)
    if not source.exists():
        if args.gl4es_source or args.offline:
            raise BuildError("Pinned GL4ES source is missing. Pass --gl4es-source /path/to/checkout or run once without --offline.")
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "--quiet", str(source)], check=True, env=env)
        subprocess.run(["git", "-C", str(source), "remote", "add", "origin", build_gl4es.UPSTREAM], check=True, env=env)
    try:
        actual = capture(["git", "-C", source, "rev-parse", "HEAD"], env)
    except subprocess.SubprocessError:
        actual = None
    if actual is None and not args.gl4es_source and not args.offline:
        if capture(["git", "-C", source, "remote", "get-url", "origin"], env) != build_gl4es.UPSTREAM:
            raise BuildError("Cached GL4ES repository has an unexpected origin; provide a clean pinned checkout with --gl4es-source")
        for attempt in range(1, 4):
            try:
                run_step(report, output, env, f"fetch-gl4es-{attempt}", ["git", "-C", source, "-c", "http.lowSpeedLimit=1024",
                    "-c", "http.lowSpeedTime=30", "fetch", "--depth=1", "origin", build_gl4es.COMMIT], timeout=180)
                break
            except BuildError:
                if attempt == 3:
                    raise
                status(f"Retrying public GL4ES download ({attempt + 1}/3)…")
                time.sleep(attempt)
        run_step(report, output, env, "checkout-gl4es", ["git", "-C", source, "checkout", "--detach", build_gl4es.COMMIT])
        actual = capture(["git", "-C", source, "rev-parse", "HEAD"], env)
    if actual != build_gl4es.COMMIT:
        raise BuildError("GL4ES source must be at the pinned commit " + build_gl4es.COMMIT + "; cache/source is preserved for inspection")
    if subprocess.run(["git", "-C", str(source), "diff", "--quiet", "HEAD", "--"], env=env).returncode:
        raise BuildError("GL4ES checkout has tracked modifications; provide an unmodified pinned checkout")
    return source


def build(args):
    app, steam = source_paths(args)
    status("Verifying your local game and the eight allowlisted Steam binaries…")
    inputs = checked_inputs(app, steam)
    environment = doctor(args)
    if not environment["ok"]:
        raise BuildError("Environment check failed; run python3 scripts/build.py doctor for details")
    WORK.mkdir(exist_ok=True)
    output = args.output.expanduser() if args.output else WORK / ("build-" + datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6])
    if not output.is_absolute():
        output = ROOT / output
    if output.exists() or output.is_symlink():
        raise BuildError("Output already exists; choose a new --output. Previous builds and logs are preserved.")
    output = output.resolve()
    if output == WORK.resolve() or not output.is_relative_to(WORK.resolve()):
        raise BuildError("--output must be a fresh subdirectory of this checkout's work/")
    if output.exists() or output.is_symlink():
        raise BuildError("Output already exists; choose a new --output. Previous builds and logs are preserved.")
    for original in (app, steam, args.gl4es_source):
        if original and (output == original.resolve() or output.is_relative_to(original.resolve()) or original.resolve().is_relative_to(output)):
            raise BuildError("Build output overlaps an original input")
    output.mkdir(parents=True)
    marker = output / "INCOMPLETE"
    marker.write_text("Build incomplete; do not sign or install this output.\n")
    report = {"schema_version": 1, "status": "incomplete", "started_at": datetime.now(timezone.utc).isoformat(),
              "inputs": inputs, "environment": environment, "steps": [], "signed": False, "installed": False,
              "layout_profile": None if args.no_layout else "ipad-layout-v7.json"}
    def tool(name, *values):
        return [sys.executable, "-B", str(TOOLS / name), *map(str, values)]
    try:
        env = bootstrap_tools(developer_environment(), args.offline)
        source = gl4es_source(args, env, report, output)
        run_step(report, output, env, "01-gl4es", tool("build_gl4es.py", "--source", source, "--output", output / "gl4es"))
        run_step(report, output, env, "02-game-boundaries", tool("build_loader_boundaries.py", "--survey", GAME_SURVEY,
            "--output", output / "game-boundaries", "--graphics-runtime", "--filesystem-runtime", "--audio-runtime", "--steam-ipc-runtime"))
        run_step(report, output, env, "03-steam-preliminary", tool("stage_steam_client.py", "--source", steam,
            "--profile", STEAM_PROFILE, "--output", output / "steam-preliminary"))
        run_step(report, output, env, "04-steam-boundaries", tool("build_steam_boundaries.py", "--survey", STEAM_SURVEY,
            "--client-stage", output / "steam-preliminary", "--game-boundaries", output / "game-boundaries",
            "--dispatch-leases", "--output", output / "steam-boundaries"))
        run_step(report, output, env, "05-steam-client", tool("stage_steam_client.py", "--source", steam,
            "--profile", STEAM_PROFILE, "--boundaries", output / "steam-boundaries", "--output", output / "steam-client"))
        arguments = tool("rebuild_personal_app.py", "execute", "--app", app, "--profile", GAME_PROFILE,
            "--boundaries", output / "game-boundaries", "--gl4es-build", output / "gl4es",
            "--steam-stage", output / "steam-client", "--steam-boundaries", output / "steam-boundaries",
            "--steam-profile", STEAM_PROFILE, "--steam-init-bridge", "--steam-sdk-client-order-fix",
            "--steam-online-launch", "--output", output / "app")
        if not args.no_layout:
            arguments.extend(["--ipad-layout-mod", str(KIT / "profiles/ipad-layout-v7.json")])
        run_step(report, output, env, "06-unsigned-app", arguments)
        report.update(status="built_unsigned_not_runtime_validated", bundle=str(output / "app/TFM2Probe.app"),
                      completed_at=datetime.now(timezone.utc).isoformat())
        (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
        marker.unlink()
        return {"status": report["status"], "bundle": report["bundle"], "report": str(output / "build-report.json"),
                "next": "Use scripts/install.py --help to sign a copy with your own Apple development identity."}
    except BaseException as error:
        report["error"] = str(error)
        (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
        raise


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", nargs="?", choices=("doctor", "check", "build"), default="build")
    result.add_argument("--app", type=Path, help="Your installed Mac Steam TeamfightManager2.app (auto-discovered)")
    result.add_argument("--steam-contents", type=Path, help="Installed Steam.AppBundle/Steam/Contents (auto-discovered)")
    result.add_argument("--gl4es-source", type=Path, help="Existing unmodified GL4ES checkout at the pinned commit; otherwise fetched into work/cache")
    result.add_argument("--output", type=Path, help="Fresh directory under work/; relative paths are relative to the checkout")
    result.add_argument("--offline", action="store_true", help="Disable all dependency downloads; require local tools and pinned GL4ES source")
    result.add_argument("--no-layout", action="store_true", help="Keep the original game layout instead of the reviewed v7 iPad layout")
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command == "doctor":
            report = doctor(args)
            print(json.dumps(report, indent=2))
            return 0 if report["ok"] else 1
        if args.command == "check":
            report = checked_inputs(*source_paths(args))
        else:
            report = build(args)
        print(json.dumps(report, indent=2))
        return 0
    except (BuildError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "blocked", "error": str(error)}, indent=2), file=sys.stderr)
        return 2 if args.command == "check" else 1
    except KeyboardInterrupt:
        status("Interrupted. Incomplete outputs are preserved; run again with a fresh output directory.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
