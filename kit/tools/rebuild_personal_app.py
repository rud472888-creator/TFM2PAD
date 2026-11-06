#!/usr/bin/env python3
"""Check pinned local inputs, plan read-only, or explicitly rebuild a fresh personal app.

Never downloads Steam content, updates a pin, authenticates, launches a game,
or touches device saves. Installation requires both execute and --install.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

# Even importing validators during a read-only plan must not create caches.
sys.dont_write_bytecode = True
import portkit
import build_gl4es

ROOT = Path(__file__).resolve().parents[1]
WORK_ROOT = ROOT.parent / "work"
MAIN_STACK_BYTES = 8 * 1024 * 1024
LAUNCH_MODE_KEY = "TFMPersonalLaunchMode"
ONLINE_LAUNCH_MODE = "steam-online"
ONLINE_DISPLAY_NAME = "TFM2 iPad"
LAUNCH_RECORD = "personal-launch.json"


class InputChanged(ValueError):
    def __init__(self, changes):
        self.changes = changes
        super().__init__("Pinned inputs changed: " + ", ".join(changes) +
                         ". Run audit_game.py, review imports/runtime requirements, then create a separately reviewed profile and matching boundary survey. This tool never updates pins.")


def read_json(path):
    return json.loads(Path(path).read_text())


def fingerprint(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular, non-symlink input file: " + str(path))
    return {"sha256": portkit.sha256(path), "size": path.stat().st_size}


def check_inputs(app, profile):
    pinned = read_json(profile)
    if pinned.get("schema") != 1 or pinned.get("app_id") != portkit.APP_ID:
        raise ValueError("Expected a schema1 AppID3009300 portkit input profile")
    current = portkit.observe(app)
    changes = portkit.differences(pinned, current)
    return {"local_source_changed": bool(changes), "changed": changes,
            "scope": "installed local Steam copy only; no server latest-version query",
            "action": "re-audit and review a new pin/boundary survey before rebuilding" if changes else "pinned local inputs match; runtime compatibility remains unverified"}, current


def fresh_destination(path, protected):
    raw = Path(path).expanduser()
    if raw.exists() or raw.is_symlink():
        raise ValueError("Output must not exist; existing builds are preserved")
    output = raw.resolve()
    work = WORK_ROOT.resolve()
    if output == work or work not in output.parents or not output.parent.is_dir():
        raise ValueError("Use a fresh directory below the project's work/ with an existing parent")
    for source in protected:
        source = Path(source).resolve()
        if output == source or source in output.parents or output in source.parents:
            raise ValueError("Output overlaps a protected source or input: " + str(source))
    return output


def completed_artifacts(directory, status, key, tracked, *, nested=False):
    directory = Path(directory).resolve(strict=True)
    report_path = directory / "build-report.json"
    if (directory / "INCOMPLETE").exists():
        raise ValueError("Build input is incomplete: " + str(directory))
    report = read_json(report_path)
    if report.get("schema_version") != 1 or report.get("status") != status:
        raise ValueError("Unexpected build report schema/status: " + str(report_path))
    commands = report.get("commands")
    if not commands or any(item.get("exit_code") != 0 for item in commands):
        raise ValueError("Build report contains missing or failed commands")
    tracked[str(report_path)] = fingerprint(report_path)
    entries = report.get(key)
    if not isinstance(entries, list) or not entries:
        raise ValueError("Build report contains no artifacts")
    names = set()
    for item in entries:
        name = item.get("file", "")
        relative = Path(name)
        if not name or relative.is_absolute() or ".." in relative.parts or (not nested and relative.name != name) or name in names:
            raise ValueError("Invalid/duplicate artifact path")
        names.add(name)
        path = directory / relative
        if directory not in path.resolve().parents:
            raise ValueError("Artifact escapes its build directory")
        actual = fingerprint(path)
        if actual["sha256"] != item.get("sha256") or ("size" in item and actual["size"] != item["size"]):
            raise ValueError("Artifact differs from build report: " + name)
        tracked[str(path)] = actual
    return report


def toolkit_fingerprints():
    paths = set()
    for folder in ("tools", "compat", "probe", "vendor/agepad"):
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and path.suffix in {".py", ".m", ".mm", ".c", ".h", ".inc", ".S", ".s", ".json"}:
                paths.add(path)
    return {str(path): fingerprint(path) for path in sorted(paths)}


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", nargs="?", choices=("check", "plan", "execute"), default="plan")
    result.add_argument("--app", required=True, type=Path, help="Owned original Mac app; read only")
    result.add_argument("--profile", required=True, type=Path, help="Existing pinned portkit input profile; never rewritten")
    result.add_argument("--boundaries", type=Path, help="Existing complete game boundary build for this game hash")
    result.add_argument("--gl4es-build", type=Path, help="Existing complete pinned GL4ES build")
    result.add_argument("--output", type=Path, help="Fresh directory below this project's work/")
    result.add_argument("--ipad-layout-mod", type=Path, help="Optional reviewed reversible iPad layout profile; original game/assets remain unchanged")
    result.add_argument("--steam-stage", type=Path, help="Optional already staged eight-image client; no installed account files read")
    result.add_argument("--steam-boundaries", type=Path)
    result.add_argument("--steam-profile", type=Path)
    result.add_argument("--steam-init-bridge", action="store_true", help="Opt-in combined-mode SDK Init wrapper; requires shared IPC boundaries and existing complete Steam stage")
    result.add_argument("--steam-sdk-client-order-fix", action="store_true", help="Opt-in SDK-only client ABI provider; requires existing complete Steam stage/shared IPC")
    result.add_argument("--steam-online-launch", action="store_true", help="Opt in to normal-icon Steam online launch after both bridges, assets and client staging are verified")
    result.add_argument("--signing-profile", type=Path, help="Existing .mobileprovision; signing is opt-in with all three signing arguments")
    result.add_argument("--identity", help="Existing signing certificate SHA-1")
    result.add_argument("--device", help="Device UDID authorized by that provisioning profile")
    result.add_argument("--install", action="store_true", help="Explicit execute-only device installation; never launches or removes an app")
    return result


def validate_arguments(args):
    if args.command == "check" and args.ipad_layout_mod:
        raise ValueError("--ipad-layout-mod requires plan/execute")
    signing = [args.signing_profile, args.identity, args.device]
    if any(signing) and not all(signing):
        raise ValueError("Signing requires --signing-profile, --identity and --device together")
    if args.identity and not re.fullmatch(r"[A-Fa-f0-9]{40}", args.identity):
        raise ValueError("--identity must be an existing certificate's 40-hex SHA-1")
    steam = [args.steam_stage, args.steam_boundaries, args.steam_profile]
    if any(steam) and not all(steam):
        raise ValueError("Steam bundling requires --steam-stage, --steam-boundaries and --steam-profile together")
    if args.steam_init_bridge and (args.command == "check" or not all(steam)):
        raise ValueError("--steam-init-bridge requires plan/execute and all three existing Steam staging arguments")
    if args.steam_sdk_client_order_fix and (args.command == "check" or not all(steam)):
        raise ValueError("--steam-sdk-client-order-fix requires plan/execute and all three existing Steam staging arguments")
    if args.steam_online_launch and (args.command == "check" or not args.steam_init_bridge or not args.steam_sdk_client_order_fix or not all(steam)):
        raise ValueError("--steam-online-launch requires plan/execute, both Steam bridges and all three existing Steam staging arguments")
    if args.install and (args.command != "execute" or not all(signing)):
        raise ValueError("--install requires execute and all three signing arguments")
    if args.command == "check" and (any(signing) or any(steam) or args.install):
        raise ValueError("check only inspects the local game/profile; use plan for build options")
    if args.command != "check" and not all((args.boundaries, args.gl4es_build, args.output)):
        raise ValueError("plan/execute requires --boundaries, --gl4es-build and --output")


def make_plan(args):
    validate_arguments(args)
    app = args.app.expanduser().resolve(strict=True)
    profile = args.profile.expanduser().resolve(strict=True)
    check, current = check_inputs(app, profile)
    if check["local_source_changed"]:
        raise InputChanged(check["changed"])
    protected = [app, profile, args.boundaries, args.gl4es_build]
    protected += [value for value in (args.steam_stage, args.steam_boundaries, args.steam_profile, args.signing_profile, args.ipad_layout_mod) if value]
    output = fresh_destination(args.output, protected)
    tracked = {str(profile): fingerprint(profile)}
    layout_input = None
    if args.ipad_layout_mod:
        layout_profile = args.ipad_layout_mod.expanduser().resolve(strict=True)
        layout_pin = fingerprint(layout_profile)
        recipe = read_json(layout_profile)
        if (recipe.get("schema") != 1 or str(recipe.get("app_id")) != portkit.APP_ID or
                recipe.get("original_game_universal_sha256") != current["files"]["game"]["sha256"] or
                recipe.get("original_assets_sha256") != current["files"]["data"]["sha256"]):
            raise ValueError("Layout profile differs from the pinned original game/assets")
        tracked[str(layout_profile)] = layout_pin
        layout_input = {"profile": str(layout_profile), **layout_pin, "profile_id": recipe["id"]}
    adapter = portkit.ROOT / "vendor/agepad/prepare-de-load-image.py"
    tracked[str(adapter)] = fingerprint(adapter)
    if tracked[str(adapter)]["sha256"] != portkit.ADAPTER_SHA256:
        raise ValueError("Vendored AgePad adapter differs from its reviewed digest")
    boundaries = args.boundaries.expanduser().resolve(strict=True)
    gl4es = args.gl4es_build.expanduser().resolve(strict=True)
    build = completed_artifacts(boundaries, "built_load_only_boundaries", "boundaries", tracked)
    if build.get("survey_source", {}).get("sha256") != current["files"]["game"]["sha256"]:
        raise ValueError("Boundary survey is from another game binary; obtain a reviewed survey/build for this pin")
    if not build.get("graphics_runtime_enabled") or not build.get("filesystem_runtime_enabled"):
        raise ValueError("Current game pipeline requires complete --graphics-runtime and --filesystem-runtime boundaries")
    bridge_input = None
    if args.steam_init_bridge:
        import steam_init_bridge_build as bridge
        if not build.get("steam_ipc_runtime_enabled") or not build.get("shared_steam_ipc"):
            raise ValueError("Steam init bridge requires a complete shared Steam IPC boundary build")
        if "_TFMSteamIPCPrepareForGame" not in build["shared_steam_ipc"].get("all_direct_exports", []):
            raise ValueError("Steam init bridge needs shared IPC PrepareForGame; rebuild the game and Steam boundary packages")
        _, originals = portkit.source_files(app)
        bridge_input = {"original_input": bridge.inspect_input_sdk(originals["steam_sdk"], current["files"]["steam_sdk"]),
                        "source_hashes": bridge.source_hashes()}
    client_boundary_input = None
    runtime_fixes_input = None
    if args.steam_sdk_client_order_fix:
        import steam_sdk_client_build as client_boundary
        import steam_init_bridge_build as sdk_pins
        _, originals = portkit.source_files(app)
        client_boundary_input = {"source_hashes": client_boundary.source_hashes(),
                                 "common_runtime": client_boundary.common_input(boundaries, build),
                                 "original_sdk_input": sdk_pins.inspect_input_sdk(originals["steam_sdk"], current["files"]["steam_sdk"]),
                                 "original_game_input": client_boundary.game_input(originals["game"], current["files"]["game"])}
    mapping = boundaries / "dependency-map.json"
    dependency_map = read_json(mapping)
    names = {item["file"] for item in build["boundaries"]}
    if not isinstance(dependency_map, dict) or not dependency_map or any(
            not isinstance(target, str) or target != "@rpath/" + Path(target).name or Path(target).name not in names
            for target in dependency_map.values()):
        raise ValueError("Game boundary dependency map does not match its verified artifacts")
    tracked[str(mapping)] = fingerprint(mapping)
    gl_report = completed_artifacts(gl4es, "compiled_not_device_validated", "artifacts", tracked, nested=True)
    if gl_report.get("commit") != build_gl4es.COMMIT or gl_report.get("upstream") != build_gl4es.UPSTREAM:
        raise ValueError("GL4ES upstream/commit differs from toolkit pin")
    if "TFMGL4ES.dylib" not in {item["file"] for item in gl_report["artifacts"]} or not any(
            "-DNO_INIT_CONSTRUCTOR=ON" in item.get("argv", []) for item in gl_report["commands"]):
        raise ValueError("Pinned GL4ES dylib/disabled initializer evidence is missing")
    target = output / "TFM2Probe.app"
    library_pins = {item["file"]: item["sha256"] for item in build["boundaries"]}
    if "TFMGL4ES.dylib" in library_pins:
        raise ValueError("GL4ES filename collides with a game boundary")
    library_pins["TFMGL4ES.dylib"] = next(item["sha256"] for item in gl_report["artifacts"] if item["file"] == "TFMGL4ES.dylib")
    python = str(Path(sys.executable).resolve())
    def tool(name, *arguments):
        return [python, str(ROOT / "tools" / name), *map(str, arguments)]
    steps = [
        {"name": "check-updates", "argv": tool("portkit.py", "check-updates", "--app", app, "--profile", profile)},
        {"name": "build-host", "argv": tool("build_probe.py", "--app", app, "--output", target, "--main-stack-size", MAIN_STACK_BYTES)},
        {"name": "stage-images", "argv": tool("stage_loader_images.py", "--app", app, "--profile", profile, "--boundaries", boundaries, "--gl4es-build", gl4es, "--probe-app", target)},
        {"name": "stage-assets", "argv": tool("stage_game_assets.py", "--app", app, "--profile", profile, "--probe-app", target)},
    ]
    if args.steam_init_bridge:
        steps[2]["argv"].append("--steam-init-bridge")
    if args.steam_sdk_client_order_fix:
        steps[2]["argv"].append("--steam-sdk-client-order-fix")
    if layout_input:
        steps.append({"name": "stage-ipad-layout", "argv": tool("stage_ipad_layout.py",
            "--game", target / "Frameworks/TeamfightManager2.dylib", "--assets", target / "bundle.game_data",
            "--profile", layout_input["profile"], "--output", output / "ipad-layout-stage")})
    if args.steam_stage:
        import bundle_steam_client as bundling
        import stage_steam_client as staging
        stage_dir = args.steam_stage.expanduser().resolve(strict=True)
        steam_boundaries = args.steam_boundaries.expanduser().resolve(strict=True)
        steam_profile = args.steam_profile.expanduser().resolve(strict=True)
        stage, pins, files = bundling.validate_client_stage(stage_dir, steam_profile)
        _, steam = staging.validate_steam_boundaries(steam_boundaries, staging.profile_identities(pins))
        if stage["boundary_package"] != steam:
            raise ValueError("Steam stage was remapped against a different Steam boundary package")
        for item in steam["required_existing_game_libraries"]:
            path = boundaries / item["file"]
            if fingerprint(path)["sha256"] != item["sha256"]:
                raise ValueError("Steam boundaries depend on different game boundaries; rebuild/remap that Steam stage first")
        for path in (steam_profile, stage_dir / "steam-client-stage.json", steam_boundaries / "build-report.json", steam_boundaries / "dependency-map.json"):
            tracked[str(path)] = fingerprint(path)
        for item in files:
            tracked[str(item["source"])] = fingerprint(item["source"])
            if item["file"] in library_pins: raise ValueError("Steam image collides with a game/GL4ES library")
            library_pins[item["file"]] = item["sha256"]
        for item in steam["libraries"]:
            path = steam_boundaries / item["file"]; tracked[str(path)] = fingerprint(path)
            if item["file"] in library_pins: raise ValueError("Steam boundary collides with an existing library")
            library_pins[item["file"]] = item["sha256"]
        steps.append({"name": "bundle-steam", "argv": tool("bundle_steam_client.py", "--client-stage", stage_dir, "--boundaries", steam_boundaries, "--profile", steam_profile, "--probe-app", target)})
        if args.steam_online_launch:
            import steam_runtime_fixes as runtime_fixes
            runtime_fixes_input = runtime_fixes.plan_input(library_pins)
            steps.append({"name": "stage-steam-runtime-fixes", "argv": tool("steam_runtime_fixes.py", "--bundle", target)})
    steps.append({"name": "recheck-updates", "argv": tool("portkit.py", "check-updates", "--app", app, "--profile", profile)})
    if args.signing_profile:
        signing = args.signing_profile.expanduser().resolve(strict=True)
        tracked[str(signing)] = fingerprint(signing)
        steps.append({"name": "sign", "argv": tool("sign_probe.py", "--app", target, "--profile", signing, "--identity", args.identity, "--device", args.device)})
    if args.install:
        steps.append({"name": "install", "argv": ["xcrun", "devicectl", "device", "install", "app", "--device", args.device, str(target)]})
    return {"schema_version": 1, "status": "read_only_plan", "app": str(app), "profile": str(profile),
            "original_inputs": current, "output": str(output), "bundle": str(target), "main_stack_bytes": MAIN_STACK_BYTES,
            "input_fingerprints": tracked, "toolkit_fingerprints": toolkit_fingerprints(), "steps": steps,
            "staged_library_pins": library_pins,
            "ipad_layout_mod": layout_input,
            "steam_online_launch_enabled": args.steam_online_launch,
            "steam_runtime_fixes_enabled": args.steam_online_launch, "steam_runtime_fixes_input": runtime_fixes_input,
            "personal_launch_mode": ONLINE_LAUNCH_MODE if args.steam_online_launch else None,
            "steam_init_bridge_enabled": args.steam_init_bridge, "steam_init_bridge_input": bridge_input,
            "steam_sdk_client_order_fix_enabled": args.steam_sdk_client_order_fix, "steam_sdk_client_order_fix_input": client_boundary_input,
            "sign_requested": bool(args.signing_profile), "install_requested": args.install,
            "limitations": ["Reuses explicit prebuilt boundary/GL4ES artifacts; does not rebuild or approve their runtime behavior",
                            "Reproducible commands and input hashes, not byte-identical compiler/signing timestamps",
                            "No Steam download/authentication, game launch, save migration, account files or device-container cleanup",
                            "Signing profile/certificate/device authorization is checked by sign_probe.py during execute",
                            "Online icon launch is enabled only by the explicit packaging flag; build success is not gameplay validation"]}


def verify_plan_inputs(plan):
    for path, expected in plan["input_fingerprints"].items():
        if fingerprint(path) != expected:
            raise ValueError("Build input changed since planning: " + path)
    if toolkit_fingerprints() != plan["toolkit_fingerprints"]:
        raise ValueError("Toolkit source changed during rebuild; use a fresh plan/output after source freeze")
    check, _ = check_inputs(Path(plan["app"]), Path(plan["profile"]))
    if check["local_source_changed"]:
        raise InputChanged(check["changed"])


def write_report(path, report):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(path)


def verify_staged_bundle(plan, *, launch_policy_pending=False):
    """Verify unsigned staged bytes before any signing or installation."""
    bundle = Path(plan["bundle"])
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("Build command did not produce a regular app directory")
    for name in ("ProbeBuildIncomplete", "LoaderStageIncomplete", "AssetStageIncomplete", "SteamStageIncomplete", "LayoutStageIncomplete", "SteamRuntimeFixesIncomplete"):
        if (bundle / name).exists():
            raise ValueError("Staged bundle still has an incomplete marker: " + name)
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    icon_record = bundle / "original-icon-stage.json"
    if icon_record.exists():
        icon = read_json(icon_record)
        for name, digest in icon.get("artifacts", {}).items():
            if Path(name).name != name or fingerprint(bundle / name)["sha256"] != digest:
                raise ValueError("Original game icon artifact differs from staged bytes")
        if "Assets.car" not in icon.get("artifacts", {}) or not icon.get("plist_keys"):
            raise ValueError("Original game icon staging is incomplete")
        if any(info.get(key) != value for key, value in icon["plist_keys"].items()):
            raise ValueError("Original game icon plist configuration differs from staging")
    online = bool(plan.get("steam_online_launch_enabled"))
    runtime_fixes_enabled = bool(plan.get("steam_runtime_fixes_enabled"))
    if online != runtime_fixes_enabled:
        raise ValueError("Online launch requires both planned Steam runtime stability fixes")
    if online and (not plan.get("steam_init_bridge_enabled") or not plan.get("steam_sdk_client_order_fix_enabled") or not any(s["name"] == "bundle-steam" for s in plan["steps"])):
        raise ValueError("Online launch requires both planned bridges and complete Steam client staging")
    launch_record = bundle / LAUNCH_RECORD
    if online and not launch_policy_pending:
        if info.get("LSSupportsGameMode") is not True or info.get("LSApplicationCategoryType") != "public.app-category.games":
            raise ValueError("Personal game bundle is missing its Game Mode registration")
        if info.get(LAUNCH_MODE_KEY) != ONLINE_LAUNCH_MODE or info.get("CFBundleDisplayName") != ONLINE_DISPLAY_NAME or not launch_record.is_file() or launch_record.is_symlink():
            raise ValueError("Online launch plist policy or provenance is missing/tampered")
        expected_launch = {"schema_version": 1, "mode": ONLINE_LAUNCH_MODE, "prerequisites_verified": True,
                           "info_plist_sha256_before_signing": fingerprint(bundle / "Info.plist")["sha256"]}
        if read_json(launch_record) != expected_launch:
            raise ValueError("Online launch plist/provenance differs from validated bytes")
    elif LAUNCH_MODE_KEY in info or launch_record.exists() or launch_record.is_symlink():
        raise ValueError("Unexpected launch policy; default/pending build must have no personal launch key or record")
    host = read_json(bundle / "probe-build.json")
    if info.get("CFBundleIdentifier") != "org.tfm2pad.staging" or info.get("TFMRequestedMainStackBytes") != MAIN_STACK_BYTES or host.get("requested_main_stack_bytes") != MAIN_STACK_BYTES or host.get("status") != "compiled_not_signed":
        raise ValueError("Host bundle identity, requested 8MiB stack or build status is wrong")
    if fingerprint(bundle / "TFM2Probe")["sha256"] != host.get("executable_sha256_before_signing"):
        raise ValueError("Unsigned host executable differs from its build record")
    loader = read_json(bundle / "loader-stage.json")
    layout_enabled = bool(plan.get("ipad_layout_mod"))
    if not layout_enabled and ((bundle / "layout-stage.json").exists() or (bundle / "layout-stage.json").is_symlink()):
        raise ValueError("Unexpected layout-stage record; layout modification was not planned")
    if loader.get("status") != "staged_for_load_only_probe" or portkit.differences(plan["original_inputs"], loader.get("original_inputs", {})):
        raise ValueError("Staged loader inputs differ from pinned originals")
    if set(loader.get("images", {})) != {"game", "steam_sdk"}:
        raise ValueError("Staged game/Steam SDK image records are missing")
    bridge_enabled = bool(plan.get("steam_init_bridge_enabled"))
    if bool(loader.get("steam_init_bridge_enabled")) != bridge_enabled:
        raise ValueError("Staged SDK bridge mode differs from the explicit plan")
    for role, name in (("game", "TeamfightManager2.dylib"), ("steam_sdk", "libsteam_api.dylib")):
        if role == "steam_sdk" and bridge_enabled:
            name = "TFMOriginalSteamAPI.dylib"
            if loader["images"][role].get("output") != "Frameworks/" + name:
                raise ValueError("Bridge original SDK must have its unique staged filename")
        if not (role == "game" and layout_enabled) and fingerprint(bundle / "Frameworks" / name)["sha256"] != loader["images"][role].get("output_sha256"):
            raise ValueError("Staged image differs from its recorded bytes: " + role)
    if bridge_enabled:
        import steam_init_bridge_build as bridge
        bridge_report = loader.get("steam_init_bridge")
        if not isinstance(bridge_report, dict) or bridge_report.get("source_hashes") != plan["steam_init_bridge_input"]["source_hashes"]:
            raise ValueError("SDK bridge provenance/source hashes differ from the plan")
        bridge.validate(bundle / "Frameworks", bridge_report, plan["steam_init_bridge_input"]["original_input"])
        if bridge.WRAPPER_ID not in bridge.metadata((bundle / "Frameworks/TeamfightManager2.dylib").read_bytes())["loads"]:
            raise ValueError("Staged game no longer imports the expected SDK wrapper")
    client_fix_enabled = bool(plan.get("steam_sdk_client_order_fix_enabled"))
    if bool(loader.get("steam_sdk_client_order_fix_enabled")) != client_fix_enabled:
        raise ValueError("Staged SDK client-order provider mode differs from the explicit plan")
    if client_fix_enabled:
        import steam_sdk_client_build as client_boundary
        if layout_enabled:
            validate_layout_bundle(plan, bundle)
        client_boundary.validate(bundle / "Frameworks", loader.get("steam_sdk_client_order_fix"),
                                 plan["steam_sdk_client_order_fix_input"], bridge_enabled,
                                 **({"layout_profile": plan["ipad_layout_mod"]["profile"]} if layout_enabled else {}))
    final_library_pins = dict(plan["staged_library_pins"])
    if runtime_fixes_enabled:
        import steam_runtime_fixes as runtime_fixes
        if plan.get("steam_runtime_fixes_input") != runtime_fixes.plan_input(plan["staged_library_pins"]):
            raise ValueError("Steam runtime fix plan input pins/provenance changed")
        runtime_fix_record = runtime_fixes.verify(bundle)
        final_library_pins.update(runtime_fix_record["output_library_pins"])
    elif any(path.exists() or path.is_symlink() for path in (bundle / "steam-runtime-fixes.json", bundle / "Frameworks/TFMSteamDesktopAudio.dylib")):
        raise ValueError("Unexpected Steam runtime fixes outside the online-launch plan")
    for name, digest in final_library_pins.items():
        if fingerprint(bundle / "Frameworks" / name)["sha256"] != digest:
            raise ValueError("Copied runtime library differs from planned bytes: " + name)
    assets = read_json(bundle / "asset-stage.json")
    expected = plan["original_inputs"]["files"]["data"]
    if assets.get("status") != "copied_and_hash_verified_not_runtime_validated" or assets.get("source") != expected or assets.get("game_sha256") != plan["original_inputs"]["files"]["game"]["sha256"]:
        raise ValueError("Asset staging metadata differs from the pinned game")
    if layout_enabled:
        validate_layout_bundle(plan, bundle)
    elif fingerprint(bundle / "bundle.game_data") != {"sha256": expected["sha256"], "size": expected["size"]}:
        raise ValueError("Staged assets differ from pinned bytes")
    if any(step["name"] == "bundle-steam" for step in plan["steps"]):
        if read_json(bundle / "steam-stage.json").get("status") != "staged_for_optional_steam_client_load_not_executed":
            raise ValueError("Requested Steam client bundling did not complete")
    return {"unsigned_staged_bytes_verified": True, "game_main_executed": False,
            "ipad_layout_mod_verified": layout_enabled,
            "steam_runtime_fixes_verified": runtime_fixes_enabled,
            "personal_launch_mode": ONLINE_LAUNCH_MODE if online and not launch_policy_pending else None}


def layout_anchors(plan, bundle, *, require_original_bytes=False):
    """Use independent pre-layout loader/asset records, never layout post-hashes."""
    layout = plan["ipad_layout_mod"]
    if fingerprint(layout["profile"]) != {k: layout[k] for k in ("sha256", "size")}:
        raise ValueError("Layout profile changed since planning")
    loader = read_json(bundle / "loader-stage.json")
    assets = read_json(bundle / "asset-stage.json")
    expected = plan["original_inputs"]["files"]["data"]
    if (loader.get("status") != "staged_for_load_only_probe" or
            portkit.differences(plan["original_inputs"], loader.get("original_inputs", {})) or
            assets.get("status") != "copied_and_hash_verified_not_runtime_validated" or
            assets.get("source") != expected or assets.get("game_sha256") != plan["original_inputs"]["files"]["game"]["sha256"]):
        raise ValueError("Layout original loader/asset metadata differs from pinned inputs")
    game_hash = loader["images"]["game"]["output_sha256"]
    if not isinstance(game_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", game_hash):
        raise ValueError("Layout requires an independent original loader game hash")
    if require_original_bytes:
        if fingerprint(bundle / "Frameworks/TeamfightManager2.dylib")["sha256"] != game_hash:
            raise ValueError("Pre-layout game differs from original loader record")
        if fingerprint(bundle / "bundle.game_data") != {"sha256": expected["sha256"], "size": expected["size"]}:
            raise ValueError("Pre-layout assets differ from original asset record")
    return game_hash, expected["sha256"]


def validate_layout_bundle(plan, bundle):
    import stage_ipad_layout as layout
    game_hash, asset_hash = layout_anchors(plan, bundle)
    for path in (bundle / "layout-stage.json", bundle / "Frameworks/TeamfightManager2.dylib", bundle / "bundle.game_data"):
        fingerprint(path)  # Refuse symlink substitutions before reverse validation.
    return layout.validate(bundle, Path(plan["ipad_layout_mod"]["profile"]), game_hash, asset_hash)


def complete_layout_stage(plan):
    import stage_ipad_layout as layout
    bundle = Path(plan["bundle"])
    game_hash, asset_hash = layout_anchors(plan, bundle, require_original_bytes=True)
    stage = Path(plan["output"]) / "ipad-layout-stage"
    if stage.is_symlink() or not stage.is_dir() or (stage / "INCOMPLETE").exists():
        raise ValueError("Layout stage did not complete")
    for name in (layout.GAME_NAME, layout.ASSET_NAME, "layout-stage.json"):
        fingerprint(stage / name)
    layout.validate(stage, Path(plan["ipad_layout_mod"]["profile"]), game_hash, asset_hash)
    for name, destination in ((layout.GAME_NAME, bundle / "Frameworks" / layout.GAME_NAME),
                              (layout.ASSET_NAME, bundle / layout.ASSET_NAME),
                              ("layout-stage.json", bundle / "layout-stage.json")):
        shutil.copyfile(stage / name, destination)
    result = validate_layout_bundle(plan, bundle)
    (bundle / "LayoutStageIncomplete").unlink()
    return result


def configure_launch_policy(plan):
    """Write the opt-in only after validating all actual unsigned staged content."""
    if not plan.get("steam_online_launch_enabled"):
        return verify_staged_bundle(plan)
    verify_staged_bundle(plan, launch_policy_pending=True)
    bundle = Path(plan["bundle"])
    path = bundle / "Info.plist"
    info = plistlib.loads(path.read_bytes())
    info[LAUNCH_MODE_KEY] = ONLINE_LAUNCH_MODE
    info["CFBundleDisplayName"] = ONLINE_DISPLAY_NAME
    info["LSSupportsGameMode"] = True
    info["LSApplicationCategoryType"] = "public.app-category.games"
    temporary = path.with_suffix(".plist.tmp")
    temporary.write_bytes(plistlib.dumps(info))
    temporary.replace(path)
    write_report(bundle / LAUNCH_RECORD, {"schema_version": 1, "mode": ONLINE_LAUNCH_MODE,
        "prerequisites_verified": True, "info_plist_sha256_before_signing": fingerprint(path)["sha256"]})
    return verify_staged_bundle(plan)


def execute_plan(plan, runner=None):
    runner = runner or subprocess.run
    verify_plan_inputs(plan)
    output = fresh_destination(plan["output"], [plan["app"], *plan["input_fingerprints"]])
    output.mkdir()  # Exclusive creation; a raced existing destination is never reused.
    marker = output / "INCOMPLETE"
    marker.write_text("Rebuild incomplete; do not sign/install this output independently.\n")
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    report = {"schema_version": 1, "status": "incomplete", "started_at": datetime.now(timezone.utc).isoformat(),
              "bundle": plan["bundle"], "steps": [], "signed": False, "installed": False, "launched": False,
              "personal_launch_mode": plan.get("personal_launch_mode"),
              "original_inputs": plan["original_inputs"], "scope": "personal rebuild orchestration; no game/Steam compatibility claim"}
    report_path = output / "rebuild-report.json"
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        for number, step in enumerate(plan["steps"], 1):
            if step["name"] in {"recheck-updates", "sign", "install"}:
                verify_plan_inputs(plan)
            if step["name"] == "sign":
                verify_staged_bundle(plan)
            if step["name"] == "stage-ipad-layout":
                verify_plan_inputs(plan)
                bundle = Path(plan["bundle"])
                if (bundle / "layout-stage.json").exists() or (bundle / "layout-stage.json").is_symlink():
                    raise ValueError("Layout record unexpectedly exists before layout staging")
                (bundle / "LayoutStageIncomplete").write_text("Layout staging incomplete; do not sign/install.\n")
                layout_anchors(plan, bundle, require_original_bytes=True)
            log = output / f"{number:02d}-{step['name']}.log"
            entry = dict(step, log=log.name)
            report["steps"].append(entry)
            with log.open("wb") as stream:
                result = runner(step["argv"], cwd=output, env=env, stdout=stream, stderr=subprocess.STDOUT, check=False)
            entry["exit_code"] = result.returncode
            write_report(report_path, report)
            if result.returncode:
                raise RuntimeError(f"{step['name']} failed ({result.returncode}); see {log}")
            if step["name"] == "stage-ipad-layout":
                report["ipad_layout_mod"] = complete_layout_stage(plan)
            if step["name"] == "stage-steam-runtime-fixes":
                import steam_runtime_fixes as runtime_fixes
                report["steam_runtime_fixes"] = runtime_fixes.verify(Path(plan["bundle"]))
            if step["name"] == "recheck-updates":
                report["staged_bundle_validation"] = configure_launch_policy(plan)
            if step["name"] == "sign": report["signed"] = True
            if step["name"] == "install": report["installed"] = True
        verify_plan_inputs(plan)
        report["status"] = "rebuilt_signed_not_runtime_validated" if report["signed"] else "rebuilt_unsigned_not_runtime_validated"
        report["completed_at"] = datetime.now(timezone.utc).isoformat()
        write_report(report_path, report)
        marker.unlink()
        return report
    except Exception as error:
        report["error_type"] = type(error).__name__
        write_report(report_path, report)
        raise


def main(argv=None):
    arguments = parser()
    args = arguments.parse_args(argv)
    try:
        validate_arguments(args)
        if args.command == "check":
            result, _ = check_inputs(args.app.expanduser().resolve(strict=True), args.profile.expanduser().resolve(strict=True))
            print(json.dumps(result, indent=2));return 2 if result["local_source_changed"] else 0
        plan = make_plan(args)
        result = execute_plan(plan) if args.command == "execute" else plan
        print(json.dumps(result, indent=2));return 0
    except InputChanged as error:
        print(json.dumps({"status": "blocked_source_changed", "changed": error.changes, "action": str(error)}, indent=2));return 2
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        arguments.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
