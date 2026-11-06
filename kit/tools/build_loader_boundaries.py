#!/usr/bin/env python3
"""Build unsigned iOS dependency boundaries from actual device survey evidence.

These resolve names for load probes and optional graphics startup experiments. Unimplemented functions
persist a symbol diagnostic and exit(78). No game, Steam binary, or account data is read.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import steam_ipc_build

ROOT = Path(__file__).resolve().parents[1]
SYMBOL = re.compile(r"_[A-Za-z][A-Za-z0-9_]*\Z")
SPECIAL_LOADER = {"dyld_stub_binder"}
REEXPORTS = {"CoreFoundation": "CoreFoundation", "CoreGraphics": "CoreGraphics", "CoreVideo": "CoreVideo", "ColorSync": "ColorSync", "CoreServices": "CoreServices", "OpenGL": "OpenGLES", "CoreAudio": "CoreAudio", "AudioToolbox": "AudioToolbox"}
ABORT_FUNCTIONS = {
    "CoreGraphics": {
        "_CGAcquireDisplayFadeReservation", "_CGDisplayCapture", "_CGDisplayFade",
        "_CGDisplayModelNumber", "_CGDisplayRelease",
        "_CGDisplaySetDisplayMode", "_CGReleaseDisplayFadeReservation",
        "_CGRestorePermanentDisplayConfiguration", "_CGSMainConnectionID",
        "_CGSSetWindowBackgroundBlurRadius", "_CGShieldingWindowLevel",
    },
    "CoreVideo": {"_CVDisplayLinkCreateWithCGDisplay", "_CVDisplayLinkGetNominalOutputVideoRefreshPeriod", "_CVDisplayLinkRelease"},
    "Carbon": {"_LMGetKbdType", "_TISCopyCurrentKeyboardLayoutInputSource", "_TISGetInputSourceProperty"},
    "ColorSync": {"_CGDisplayCreateUUIDFromDisplayID"},
    "CoreServices": {"_UCKeyTranslate"},
    "OpenGL": {"_CGLSetParameter"},
}
SUPPORTED_PROVIDERS = set(ABORT_FUNCTIONS) | {"ApplicationServices", "AppKit", "CoreFoundation", "libSystem", "CoreAudio", "AudioToolbox"}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def command(args, env, record):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record.append({"argv": args, "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args[0]}\n{result.stderr}")
    return result.stdout


def aliases(path):
    # Only the explicitly declared Mach-O aliases in this known header count as
    # display implementation coverage; function names are never guessed.
    names = set(re.findall(r'__asm__\("([^"]+)"\)', path.read_text()))
    if not names or any(not SYMBOL.fullmatch(name) for name in names):
        raise ValueError("DisplayCompat.h contains missing or unsafe asm aliases")
    return names


def abort_source(provider, symbols):
    lines = ['#include "UnimplementedBoundary.h"']
    for index, symbol in enumerate(sorted(symbols)):
        if not SYMBOL.fullmatch(symbol):
            raise ValueError(f"Unsafe imported symbol: {symbol!r}")
        name = f"TFMUnsupported_{provider}_{index}"
        # We never inspect arguments or return a value, so unknown function
        # calling signatures cannot be mistaken for implemented behavior.
        lines.extend([
            f'__attribute__((noreturn)) void {name}(void) __asm__({json.dumps(symbol)});',
            f'void {name}(void) {{ TFMAbortUnimplementedBoundary({json.dumps(provider)}, {json.dumps(symbol)}); }}',
        ])
    return lines


def cgl_error_source():
    # Numeric values taken from the installed macOS SDK CGLTypes.h. This only
    # translates an error number; it does not create or validate a CGL context.
    labels = ["invalid pixel format attribute", "invalid renderer property", "invalid pixel format",
              "invalid renderer info", "invalid context", "invalid drawable", "invalid graphics device",
              "invalid context state", "invalid numerical value", "invalid share context", "invalid enumerant",
              "invalid offscreen drawable", "invalid fullscreen drawable", "invalid window", "invalid pointer",
              "invalid code module", "invalid memory allocation", "invalid CoreGraphics connection"]
    lines = ['const char *TFMCGLErrorString(int error) __asm__("_CGLErrorString");',
             'const char *TFMCGLErrorString(int error) {',
             '  switch (error) {', '    case 0: return "no error";']
    lines += [f'    case {10000 + i}: return {json.dumps(label)};' for i, label in enumerate(labels)]
    return lines + ['    default: return "unknown CGL error (TFM2 load-only boundary)";', '  }', '}']


def export_names(nm_text):
    return {line.split()[-1] for line in nm_text.splitlines() if line.split() and not line.rstrip().endswith(":" )}


def reexport_paths(load_commands):
    paths = []
    for block in re.split(r"(?m)^Load command \d+\s*$", load_commands):
        if re.search(r"\bcmd LC_REEXPORT_DYLIB\b", block):
            match = re.search(r"\bname (.+) \(offset \d+\)", block)
            if match:
                paths.append(match[1])
    return paths


def build(args):
    survey_path = args.survey.resolve(strict=True)
    survey = json.loads(survey_path.read_text())
    libraries = survey.get("libraries")
    if not isinstance(libraries, list) or survey.get("status") != "complete":
        raise ValueError("--survey must be a completed real-device runtime survey")
    if not survey.get("device", {}).get("system_version"):
        raise ValueError("Survey has no device OS observation")
    output = args.output.resolve()
    if output.exists():
        raise ValueError("--output must be a fresh directory; existing builds are preserved")
    output.mkdir(parents=True)
    (output / "INCOMPLETE").write_text("Boundary package build incomplete. Do not load.\n")
    generated = output / "generated"
    generated.mkdir()
    env = dict(os.environ)
    commands = []
    report = {"schema_version": 1, "status": "incomplete", "purpose": "Load-only dependency boundaries, not a runnable game",
              "generated_at": datetime.now(timezone.utc).isoformat(),
              "survey_sha256": hashlib.sha256(survey_path.read_bytes()).hexdigest(),
              "survey_source": survey.get("source"), "survey_device": survey["device"],
              "boundaries": [], "dependencies": [], "excluded_loader_special_symbols": [], "commands": commands,
              "dependency_map_file": "dependency-map.json", "system_path_normalization_file": "system_path_normalization.json",
              "signing": "Not performed by this builder", "limitations": [
                  "Export coverage proves names only, not ABI/behavior compatibility.",
                  "Unimplemented function entrypoints persist boundary-failure.json, exit(78), and never return success.",
                  "DisplayCompat implements UIKit display queries; optional graphics runtime adds logical screen identity and a GL4ES-backed context.",
                  "Neither OpenGLES reexports nor GL4ES provide desktop OpenGL 4.1 compatibility.",
                  "No game or Steam binary is copied or executed; no sign-in or installation occurs.",
              ]}
    mapping, normalization = {}, {}
    try:
        sdk = command(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env, commands).strip()
        display_aliases = aliases(ROOT / "compat/DisplayCompat.h")
        with tempfile.TemporaryDirectory(prefix="tfm-boundary-modules-", dir=output.parent) as module_cache:
            ipc_shared = None
            if args.steam_ipc_runtime:
                ipc_record = steam_ipc_build.build(output, sdk, module_cache,
                    lambda argv: command(argv, env, commands))
                ipc_shared = output / ipc_record["file"]
                report["shared_steam_ipc"] = ipc_record
                report["boundaries"].append(ipc_record)
            audio_shared = None
            if args.audio_runtime:
                audio_shared = output / "TFMAudioCompat.dylib"
                audio_source = ROOT / "compat/AudioCompat.m"
                audio_header = ROOT / "compat/AudioCompat.h"
                audio_aliases = aliases(audio_header)
                audio_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (audio_source, audio_header)}
                command(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
                         "-miphoneos-version-min=15.0", "-dynamiclib", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra",
                         "-Wno-deprecated-declarations", f"-fmodules-cache-path={module_cache}",
                         "-framework", "Foundation", "-framework", "AVFAudio", "-framework", "AudioToolbox",
                         "-framework", "CoreAudio", "-Wl,-install_name,@rpath/TFMAudioCompat.dylib",
                         str(audio_source), "-o", str(audio_shared)], env, commands)
                if audio_hashes != {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (audio_source, audio_header)}:
                    raise RuntimeError("Audio source changed during compilation")
                audio_exports = export_names(command(["xcrun", "nm", "-arch", "arm64", "-gU", str(audio_shared)], env, commands))
                if audio_aliases - audio_exports:
                    raise RuntimeError("Shared audio adapter is missing declared exports")
                report["boundaries"].append({"provider": "AudioCompatShared", "file": audio_shared.name,
                    "install_name": "@rpath/TFMAudioCompat.dylib", "sha256": hashlib.sha256(audio_shared.read_bytes()).hexdigest(),
                    "direct_implemented_exports": sorted(audio_aliases), "all_direct_exports": sorted(audio_exports),
                    "sources": [{"path": p, "sha256": h} for p, h in audio_hashes.items()],
                    "scope": "One shared output-only native RemoteIO adapter, reexported by both audio providers"})
            for library in libraries:
                provider = library["provider"]
                original = library["original_path"]
                runtime = library["runtime_path"]
                system = original.startswith(("/System/Library/", "/usr/lib/"))
                if not system:
                    report["dependencies"].append({"provider": provider, "original": original, "status": "vendor_not_copied_or_mapped"})
                    continue
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_+]*", provider):
                    raise ValueError(f"Unsafe dependency provider: {provider!r}")
                normalized = re.sub(r"/Versions/[^/]+/", "/", original)
                if runtime != normalized:
                    raise ValueError(f"Unexpected runtime normalization for {provider}")
                normalization[original] = runtime
                requested = set()
                for entry in library["symbols"]:
                    if entry["status"] != "missing":
                        continue
                    symbol = entry["import"]
                    if symbol in SPECIAL_LOADER:
                        report["excluded_loader_special_symbols"].append({"provider": provider, "symbol": symbol, "reason": "Loader special symbol, not an API to implement"})
                    else:
                        if not SYMBOL.fullmatch(symbol):
                            raise ValueError(f"Unsafe/unreviewed symbol {symbol!r}")
                        requested.add(symbol)
                audio_provider = args.audio_runtime and provider in {"CoreAudio", "AudioToolbox"}
                needs_boundary = bool(requested) or library["load_status"] == "missing" or (args.graphics_runtime and provider == "CoreFoundation") or ((args.filesystem_runtime or args.steam_ipc_runtime) and provider == "libSystem") or audio_provider
                if not needs_boundary:
                    report["dependencies"].append({"provider": provider, "original": original, "target": runtime, "status": "normalized_system_dependency"})
                    continue
                if provider not in SUPPORTED_PROVIDERS:
                    raise ValueError(f"No reviewed boundary rules for {provider}")
                if provider == "AppKit" and args.skip_appkit:
                    report["dependencies"].append({"provider": provider, "original": original, "target": None, "status": "missing_boundary_skip_appkit", "requested_missing": sorted(requested)})
                    continue
                name = f"TFM{provider}.dylib"
                target = f"@rpath/{name}"
                direct_implemented = set()
                data_symbols = set()
                stubs = requested & ABORT_FUNCTIONS.get(provider, set())
                if args.graphics_runtime and provider == "OpenGL":
                    stubs.discard("_CGLSetParameter")
                if args.graphics_runtime and provider == "ColorSync":
                    stubs.discard("_CGDisplayCreateUUIDFromDisplayID")
                if args.graphics_runtime and provider == "CoreVideo":
                    stubs -= {"_CVDisplayLinkCreateWithCGDisplay", "_CVDisplayLinkGetNominalOutputVideoRefreshPeriod", "_CVDisplayLinkRelease"}
                sources = []
                source_dependencies = []
                frameworks = ["Foundation"]
                lines = abort_source(provider, stubs)
                if provider == "CoreGraphics":
                    direct_implemented = requested & display_aliases
                    sources.append(ROOT / "compat/DisplayCompat.m")
                    frameworks += ["UIKit", "Foundation"]
                elif provider == "Carbon":
                    data_symbols = requested & {"_kTISPropertyUnicodeKeyLayoutData"}
                    if data_symbols:
                        lines += ['#include <CoreFoundation/CoreFoundation.h>',
                                  'const CFStringRef TFMUnicodeKeyLayoutData __asm__("_kTISPropertyUnicodeKeyLayoutData") = CFSTR("TISPropertyUnicodeKeyLayoutData");']
                        frameworks += ["CoreFoundation"]
                elif provider == "OpenGL":
                    direct_implemented = requested & {"_CGLErrorString"}
                    if direct_implemented:
                        lines += cgl_error_source()
                    if args.graphics_runtime:
                        direct_implemented |= {"_CGLSetParameter", "_TFMOpenGLGetProcAddress"}
                        sources.append(ROOT / "compat/TFMOpenGL.m")
                        frameworks += ["UIKit", "OpenGLES", "QuartzCore"]
                elif provider == "CoreFoundation":
                    direct_implemented = {"_CFBundleGetBundleWithIdentifier", "_CFBundleGetFunctionPointerForName"}
                    sources.append(ROOT / "compat/TFMCoreFoundation.m")
                    frameworks += ["CoreFoundation"]
                elif provider == "ColorSync" and args.graphics_runtime:
                    direct_implemented = {"_CGDisplayCreateUUIDFromDisplayID"}
                    sources.append(ROOT / "compat/ColorSyncCompat.m")
                    frameworks += ["UIKit", "CoreFoundation"]
                elif provider == "CoreVideo" and args.graphics_runtime:
                    direct_implemented = {"_CVDisplayLinkCreateWithCGDisplay", "_CVDisplayLinkGetNominalOutputVideoRefreshPeriod", "_CVDisplayLinkRelease"}
                    sources.append(ROOT / "compat/CoreVideoCompat.m")
                    frameworks += ["UIKit", "CoreVideo", "CoreFoundation"]
                elif provider == "libSystem" and args.filesystem_runtime:
                    direct_implemented = {"_chdir"}
                    sources.append(ROOT / "compat/TFMFileSystem.m")
                elif audio_provider:
                    if requested:
                        raise ValueError("Audio adapter requires review for newly missing native imports")
                elif provider == "AppKit":
                    appkit_source = args.appkit_source.resolve(strict=True)
                    sources.append(appkit_source)
                    if appkit_source == (ROOT / "compat/TFMAppKit.m").resolve():
                        sources += [ROOT / "compat/TFMInputGesture.c", ROOT / "compat/TFMGameTextFocus.m"]
                        source_dependencies += [ROOT / "compat" / name for name in
                            ("TFMAppKit.h", "TFMInputGesture.h", "TFMDirectTouch.inc", "TFMGameTextFocus.h")]
                    frameworks += ["UIKit", "Foundation", "QuartzCore", "CoreGraphics", "GameController"]
                    # Actual AppKit source exports must satisfy all requested
                    # names; no synthetic constants or abort data substitutes.
                    direct_implemented = requested.copy()
                unknown = requested - direct_implemented - data_symbols - stubs
                if unknown:
                    raise ValueError(f"Unreviewed missing imports for {provider}: {sorted(unknown)}")
                source_path = generated / f"{provider}Boundary.m"
                source_path.write_text("\n".join(lines) + "\n")
                sources.insert(0, source_path)
                dylib = output / name
                clang = ["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
                         "-miphoneos-version-min=15.0", "-dynamiclib", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra",
                         "-Wno-deprecated-declarations", f"-fmodules-cache-path={module_cache}",
                         "-I", str(ROOT / "compat"), "-Wl,-install_name," + target]
                for framework in sorted(set(frameworks)):
                    clang += ["-framework", framework]
                if audio_provider:
                    # Resolve the reviewed overrides before the remaining native exports.
                    clang += ["-Wl,-reexport_library," + str(audio_shared)]
                if provider in REEXPORTS:
                    clang += ["-Wl,-reexport_framework," + REEXPORTS[provider]]
                if provider == "libSystem":
                    if ipc_shared:
                        clang += ["-Wl,-reexport_library," + str(ipc_shared)]
                    clang += ["-Wl,-reexport-lSystem"]
                clang += [str(path) for path in sources] + ["-o", str(dylib)]
                source_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources + source_dependencies}
                command(clang, env, commands)
                if source_hashes != {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources + source_dependencies}:
                    raise RuntimeError(f"{provider} source changed during compilation")
                exported_text = command(["xcrun", "nm", "-arch", "arm64", "-gU", str(dylib)], env, commands)
                exported = export_names(exported_text)
                absent = (requested | direct_implemented) - exported
                if absent:
                    raise RuntimeError(f"Built {provider} missing direct exports: {sorted(absent)}")
                loads = command(["xcrun", "otool", "-arch", "arm64", "-l", str(dylib)], env, commands)
                observed_reexports = reexport_paths(loads)
                if audio_provider and "@rpath/TFMAudioCompat.dylib" not in observed_reexports:
                    raise RuntimeError("Missing shared audio adapter reexport")
                if provider == "libSystem" and "/usr/lib/libSystem.B.dylib" not in observed_reexports:
                    raise RuntimeError("Missing real libSystem reexport")
                if provider == "libSystem" and ipc_shared:
                    steam_ipc_build.validate_reexport_order(observed_reexports)
                if provider in REEXPORTS:
                    expected = f"/System/Library/Frameworks/{REEXPORTS[provider]}.framework/{REEXPORTS[provider]}"
                    if expected not in observed_reexports:
                        raise RuntimeError(f"Missing real reexport for {provider}: {expected}")
                mapping[original] = target
                report["boundaries"].append({"provider": provider, "file": name, "install_name": target,
                    "sha256": hashlib.sha256(dylib.read_bytes()).hexdigest(), "requested_missing": sorted(requested),
                    "direct_implemented_exports": sorted(direct_implemented), "data_exports": sorted(data_symbols),
                    "failfast_exports": sorted(stubs), "all_direct_exports": sorted(exported),
                    "verified_reexports": observed_reexports, "requested_direct_exports_verified": True,
                    "sources": [{"path": str(path), "sha256": source_hashes[path]} for path in sources + source_dependencies]})
                report["dependencies"].append({"provider": provider, "original": original, "target": target, "status": "built_load_only_boundary"})
        report["status"] = "partial_appkit_missing" if args.skip_appkit else "built_load_only_boundaries"
        report["graphics_runtime_enabled"] = args.graphics_runtime
        report["filesystem_runtime_enabled"] = args.filesystem_runtime
        report["audio_runtime_enabled"] = args.audio_runtime
        report["steam_ipc_runtime_enabled"] = args.steam_ipc_runtime
        write_json(output / "dependency-map.json", mapping)
        write_json(output / "system_path_normalization.json", normalization)
        write_json(output / "build-report.json", report)
        (output / "INCOMPLETE").unlink()
    except Exception as error:
        report["error"] = str(error)
        write_json(output / "build-report.json", report)
        raise
    print(json.dumps({"output": str(output), "status": report["status"], "boundaries": len(report["boundaries"]), "missing_appkit": args.skip_appkit, "signed_or_installed": False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--survey", required=True, type=Path, help="Actual completed iPad runtime survey JSON")
    parser.add_argument("--output", required=True, type=Path, help="Fresh output directory")
    parser.add_argument("--skip-appkit", action="store_true", help="Build partial package while actual TFMAppKit.m is unavailable")
    parser.add_argument("--appkit-source", type=Path, default=ROOT / "compat/TFMAppKit.m")
    parser.add_argument("--graphics-runtime", action="store_true", help="Include explicit GL4ES-backed context and GL bundle lookup adapters")
    parser.add_argument("--filesystem-runtime", action="store_true", help="Redirect game chdir from sealed app bundle to Documents/GameRuntime with a bundled-data symlink")
    parser.add_argument("--audio-runtime", action="store_true", help="Add one shared native RemoteIO output adapter for macOS CoreAudio/AudioToolbox calls")
    parser.add_argument("--steam-ipc-runtime", action="store_true", help="Build one shared app-local Steam IPC diagnostic boundary; preserve genuine helper/SDK answers")
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
