#!/usr/bin/env python3
"""Build the default iPad API survey and optional loader diagnostics host.

This builder embeds symbol metadata only. Separately staged original binaries
may be loaded by explicit diagnostic options; entering game main is a separate
opt-in. The default API survey does not execute the original game.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
from stage_original_icon import stage_original_icon


def run(args, env):
    return subprocess.check_output(args, env=env, text=True)


def provider_name(path):
    name = Path(path).name
    # nm names /usr/lib/libSystem.B.dylib as libSystem, libc++.1 as libc++.
    return re.sub(r"(?:\.[A-Z0-9]+)*\.dylib$", "", name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Original macOS .app (read only)")
    parser.add_argument("--output", required=True, type=Path, help="Destination .app bundle")
    parser.add_argument("--main-stack-size", type=int, default=0, help="Optional Mach-O main stack request in bytes; actual runtime size must be measured")
    args = parser.parse_args()
    if args.main_stack_size and (not 65536 <= args.main_stack_size <= 33554432 or args.main_stack_size % 16384):
        parser.error("--main-stack-size must be 16KiB aligned, between 64KiB and 32MiB")
    env = dict(os.environ)
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    executable_name = info["CFBundleExecutable"]
    executable = app / "Contents/MacOS" / executable_name
    libraries_text = run(["xcrun", "otool", "-arch", "arm64", "-L", str(executable)], env)
    symbols_text = run(["xcrun", "nm", "-arch", "arm64", "-m", "-u", str(executable)], env)
    imports = defaultdict(list)
    for line in symbols_text.splitlines():
        match = re.search(r"\(undefined\).*?external\s+(\S+)\s+\(from ([^)]+)\)", line)
        if match:
            symbol, provider = match.groups()
            imports[provider].append(symbol)
        elif "(undefined)" in line:
            raise RuntimeError(f"Unparsed undefined import: {line}")
    libraries = []
    for line in libraries_text.splitlines():
        match = re.match(r"\s+(\S+) \(compatibility version", line)
        if not match:
            continue
        original = match.group(1)
        provider = provider_name(original)
        normalized = re.sub(r"/Versions/[^/]+/", "/", original)
        is_system = original.startswith(("/System/Library/", "/usr/lib/"))
        libraries.append({
            "provider": provider,
            "original_path": original,
            "runtime_path": normalized,
            "testable": is_system,
            "skip_reason": None if is_system else "Vendor library is excluded from the raw API availability survey; separate loader diagnostics may stage and load it.",
            "symbols": sorted(set(imports.pop(provider, []))),
        })
    if imports:
        raise RuntimeError(f"Imports with no dependency mapping: {sorted(imports)}")
    if not libraries or not any(x["symbols"] for x in libraries):
        raise RuntimeError("No ARM64 dependencies/imports found")
    survey = {
        "schema_version": 1,
        "purpose": "Default diagnostic API survey uses lookups only. Separately staged original game/vendor binaries may execute through explicit loader diagnostics; game main requires a separate opt-in.",
        "source": {
            "bundle_name": app.name,
            "executable_name": executable_name,
            "architecture": "arm64",
            "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "generated_at": datetime.now(timezone.utc).isoformat(),
        },
        "libraries": libraries,
        "objc_class_names": ["NSApplication", "NSWindow", "NSView", "NSOpenGLContext", "NSOpenGLPixelFormat", "NSEvent", "NSPasteboard", "NSScreen", "NSCursor", "NSMenu"],
    }
    output = args.output.resolve()
    if output.suffix != ".app":
        parser.error("--output must end in .app")
    if output == app or app in output.parents:
        parser.error("--output must be outside the original app")
    output.mkdir(parents=True, exist_ok=True)
    build_marker = output / "ProbeBuildIncomplete"
    build_marker.write_text("Probe compilation incomplete; do not sign or launch.\n")
    (output / "survey-input.json").write_text(json.dumps(survey, indent=2) + "\n")
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env).strip()
    source = Path(__file__).resolve().parents[1] / "probe/main.m"
    compat_source = source.parent.parent / "compat/DisplayCompat.m"
    gl_source = source.parent.parent / "compat/GLSurface.m"
    sources = [source, compat_source, gl_source, source.parent.parent / "compat/GL4ESRenderProbe.m",
               source.parent / "CommunityMods.m", source.parent / "GameLoaderProbe.m", source.parent / "SteamLoaderProbe.m",
               source.parent / "SteamGameCoordinator.m",
               source.parent / "SteamSDKBoundaryHost.m", source.parent / "SteamUpdateStatus.m",
               source.parent.parent / "compat/steam/SteamAppInfo.c",
               source.parent.parent / "compat/steam/SteamEngineProbe.m",
               source.parent.parent / "compat/steam/SteamCredentialStore.m",
               source.parent.parent / "compat/steam/SteamQRAuth.m"]
    provenance_sources = [*sources, source.parent.parent / "compat/steam/SteamLaunchPolicy.h",
                          source.parent.parent / "compat/steam/SteamCredentialStore.h",
                          source.parent / "SteamUpdateStatus.h", source.parent.parent / "compat/steam/SteamAppInfo.h"]
    source_hashes = {str(path.relative_to(source.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest() for path in provenance_sources}
    subprocess.run([
        "xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
        "-miphoneos-version-min=15.0", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra",
        f"-fmodules-cache-path={output.parent / '.clang-module-cache'}",
        "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "Security",
        "-framework", "OpenGLES", "-framework", "QuartzCore", "-framework", "CoreImage", "-Wno-deprecated-declarations",
        *map(str, sources),
        "-Wl,-rpath,@executable_path/Frameworks", *([f"-Wl,-stack_size,{args.main_stack_size:#x}"] if args.main_stack_size else []), "-o", str(output / "TFM2Probe"),
    ], env=env, check=True)
    if source_hashes != {str(path.relative_to(source.parent.parent)): hashlib.sha256(path.read_bytes()).hexdigest() for path in provenance_sources}:
        raise RuntimeError("Probe source changed during compilation; incomplete marker retained")
    bundle_info = {
        "CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "TFM2 API Survey",
        "CFBundleExecutable": "TFM2Probe", "CFBundleIdentifier": "org.tfm2pad.staging",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "TFM2Probe",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "7",
        "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0", "UIDeviceFamily": [2],
        "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSupportsIndirectInputEvents": True,
        "DTPlatformName": "iphoneos", "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "TFMRequestedMainStackBytes": args.main_stack_size,
        "UIApplicationSceneManifest": {
            "UIApplicationSupportsMultipleScenes": False,
            "UISceneConfigurations": {
                "UIWindowSceneSessionRoleApplication": [{
                    "UISceneConfigurationName": "Default",
                    "UISceneDelegateClassName": "ProbeSceneDelegate",
                }],
            },
        },
    }
    with (output / "Info.plist").open("wb") as f:
        plistlib.dump(bundle_info, f)
    stage_original_icon(app, output, env)
    (output / "probe-build.json").write_text(json.dumps({"status": "compiled_not_signed",
        "source_sha256": source_hashes, "requested_main_stack_bytes": args.main_stack_size,
        "executable_sha256_before_signing": hashlib.sha256((output / "TFM2Probe").read_bytes()).hexdigest(),
        "sdk": Path(sdk).name}, indent=2) + "\n")
    build_marker.unlink()
    # The parent workflow applies the device provisioning profile and signing identity.
    print(json.dumps({"bundle": str(output), "libraries": len(libraries), "imports": sum(len(x["symbols"]) for x in libraries), "signed": False}, indent=2))


if __name__ == "__main__":
    main()
