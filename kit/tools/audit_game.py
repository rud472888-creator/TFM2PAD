#!/usr/bin/env python3
"""Read-only static audit of an owned Teamfight Manager 2 Mac install.

Requires macOS lipo, otool, nm and strings; no Python dependencies. This does not
launch, patch, sign, upload or copy the game. SDK export matches are only static
candidates, not proof of arm64 iOS availability, ABI compatibility or execution.
"""
import argparse
import datetime
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

APP_ID = "3009300"
PLIST_KEYS = ("CFBundleExecutable", "CFBundleIdentifier", "CFBundleName",
              "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion")
MANIFEST_KEYS = ("appid", "name", "buildid", "installdir", "LastUpdated", "StateFlags")


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError("%s failed: %s" % (args[0], result.stderr.strip()))
    return result.stdout


def hash_file(path):
    """Reject files changed/replaced while hashing instead of recording a torn read."""
    before = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    after = path.stat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if identity(before) != identity(after):
        raise RuntimeError("File changed during audit: " + str(path))
    return {"size_bytes": after.st_size, "sha256": digest.hexdigest()}


def parse_vdf(source):
    token_pattern = re.compile(r'\s+|//[^\n]*|"((?:\\.|[^"\\])*)"|([{}])')
    tokens, offset = [], 0
    while offset < len(source):
        match = token_pattern.match(source, offset)
        if not match:
            raise ValueError("Unsupported manifest syntax at offset %d" % offset)
        offset = match.end()
        if match.group(1) is not None:
            value = re.sub(r'\\(["\\])', r'\1', match.group(1))
            tokens.append(("string", value))
        elif match.group(2):
            tokens.append((match.group(2), match.group(2)))
    index = 0

    def object_value(nested=False):
        nonlocal index
        result = {}
        while index < len(tokens):
            kind, key = tokens[index]
            index += 1
            if kind == "}":
                if not nested:
                    raise ValueError("Unexpected closing brace")
                return result
            if kind != "string" or index >= len(tokens):
                raise ValueError("Expected manifest key/value")
            kind, value = tokens[index]
            index += 1
            if key in result:
                raise ValueError("Duplicate manifest key")
            if kind == "{":
                result[key] = object_value(True)
            elif kind == "string":
                result[key] = value
            else:
                raise ValueError("Expected manifest value")
        if nested:
            raise ValueError("Unclosed manifest object")
        return result

    return object_value()


def selected_manifest(source):
    state = parse_vdf(source).get("AppState", {})
    if not isinstance(state, dict) or state.get("appid") != APP_ID:
        raise ValueError("Manifest is not AppID " + APP_ID)
    return {key: state[key] for key in MANIFEST_KEYS if key in state and isinstance(state[key], str)}


def parse_dependencies(output):
    return [match.group(1) for line in output.splitlines()
            if (match := re.match(r"\s+(.+?) \(compatibility version ", line))]


def parse_imports(output):
    entries = []
    for line in output.splitlines():
        match = re.search(r"\(undefined\)\s+(.*?)external\s+(\S+)(?:\s+\(from (.+?)\))?\s*$", line)
        if match:
            entries.append({"symbol": match.group(2), "origin": match.group(3),
                            "weak": "weak" in match.group(1)})
    return sorted(entries, key=lambda item: (item["symbol"], item["origin"] or ""))


def parse_build_versions(output):
    builds = []
    for block in output.split("Load command "):
        if "LC_BUILD_VERSION" in block:
            entry = {}
            for key in ("platform", "minos", "sdk"):
                match = re.search(r"^\s*" + key + r"\s+(\S+)", block, re.M)
                if match:
                    entry[key] = match.group(1)
            if entry.get("platform") == "1":
                entry["platform_name"] = "macOS"
            builds.append(entry)
    return builds


def normalize_dependency(name):
    return re.sub(r"(\.framework)/Versions/[^/]+/", r"\1/", name)


def parse_tbd_v4(source):
    """Extract declaration candidates from canonical YAML TAPI v3/v4 stubs.

    Target conditions and reexport closures are deliberately not resolved. Keep
    this imprecision visible to callers; never label a match a supported API.
    """
    if not re.search(r"(?:tbd-version:\s*4|!tapi-tbd-v3)", source):
        raise ValueError("Unsupported .tbd format")
    installs = set(re.findall(r"^install-name:\s*['\"]?([^'\"\n]+)", source, re.M))
    names, targets = set(), set()
    for match in re.finditer(r"targets:\s*\[([^]]*)\]", source):
        targets.update(token.strip(" '\"\n") for token in match.group(1).split(","))
    # Undefineds are declarations required BY a stub, not exports from it.
    export_sections = []
    for document in source.split("---"):
        active = False
        for line in document.splitlines():
            if line and not line[0].isspace():
                active = line.startswith(("exports:", "reexports:"))
            if active:
                export_sections.append(line)
    text = "\n".join(export_sections)
    for match in re.finditer(r"(symbols|weak-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[([^]]*)\]", text):
        key = match.group(1)
        for raw in match.group(2).split(","):
            symbol = raw.strip(" '\"\n")
            if not symbol:
                continue
            if key == "objc-classes":
                names.update(("_OBJC_CLASS_$_" + symbol, "_OBJC_METACLASS_$_" + symbol))
            elif key == "objc-eh-types":
                names.add("_OBJC_EHTYPE_$_" + symbol)
            elif key == "objc-ivars":
                names.add("_OBJC_IVAR_$_" + symbol)
            else:
                names.add(symbol)
    return {normalize_dependency(x.strip()) for x in installs}, names, targets


def find_sdk(explicit):
    if explicit:
        sdk = Path(explicit).expanduser().resolve()
        if not sdk.is_dir():
            raise ValueError("SDK directory does not exist: " + str(sdk))
        return sdk, "explicit --sdk"
    probe = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True)
    if probe.returncode == 0 and Path(probe.stdout.strip()).is_dir():
        return Path(probe.stdout.strip()).resolve(), "xcrun selected iphoneos SDK"
    candidates = list(Path("/Applications").glob("Xcode*.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"))
    if candidates:
        return sorted(candidates)[0].resolve(), "fallback installed Xcode SDK; xcrun selection unavailable"
    return None, "No local iphoneos SDK found; SDK comparison unverified"


def sdk_inventory(sdk):
    installs, exports, targets, skipped = {}, set(), set(), []
    paths = set()
    for root in (sdk / "System/Library/Frameworks", sdk / "usr/lib"):
        paths.update(path.resolve() for path in root.rglob("*.tbd"))
    for path in sorted(paths):
        try:
            names, symbols, architecture_targets = parse_tbd_v4(path.read_text())
        except (ValueError, UnicodeError):
            skipped.append(str(path.relative_to(sdk)))
            continue
        exports.update(symbols)
        targets.update(architecture_targets)
        for name in names:
            installs[name] = str(path.relative_to(sdk))
    return {"installs": installs, "exports": exports, "targets": sorted(targets),
            "stub_count": len(paths), "skipped_stubs": skipped}


def sdk_metadata(sdk):
    settings = sdk / "SDKSettings.plist"
    if not settings.is_file():
        return {}
    with settings.open("rb") as source:
        values = plistlib.load(source)
    return {key: values[key] for key in ("CanonicalName", "DisplayName", "Version") if key in values}


def compare_sdk(dependencies, imports, inventory):
    system = sorted({normalize_dependency(d) for d in dependencies if d.startswith("/")})
    missing = [d for d in system if d not in inventory["installs"]]
    symbols = sorted({entry["symbol"] for entry in imports})
    by_origin = {}
    for entry in imports:
        if entry["symbol"] not in inventory["exports"]:
            by_origin.setdefault(entry.get("origin") or "unknown", []).append(entry["symbol"])
    return {
        "system_dependencies_without_public_sdk_install_name": missing,
        "system_dependencies_with_public_sdk_install_name": [d for d in system if d not in missing],
        "non_system_dependencies_require_separate_review": sorted(d for d in dependencies if not d.startswith("/")),
        "import_declarations_not_found_in_public_sdk_scan": [s for s in symbols if s not in inventory["exports"]],
        "import_declarations_not_found_by_origin": {key: sorted(set(value)) for key, value in sorted(by_origin.items())},
        "import_declaration_candidates_found_count": sum(s in inventory["exports"] for s in symbols),
        "limitation": "All scanned target declarations are unioned; no target, deployment-version, origin/reexport, ABI or runtime resolution is proved. Not-found imports include bundled Steam and may include parser limitations. Separate from dependency-install-name gaps.",
    }


def static_markers(path):
    patterns = {"winit": re.compile(r"winit(?:[-/][0-9]+\.[0-9]+\.[0-9]+)?"),
                "glutin": re.compile(r"glutin(?:[-/][0-9]+\.[0-9]+\.[0-9]+)?"),
                "rust_source": re.compile(r"(?:\.cargo/registry|rustc/[0-9a-f]+)"),
                "NSOpenGL": re.compile(r"NSOpenGL[A-Za-z0-9_]*")}
    counts, tokens = {}, {}
    process = subprocess.Popen(["strings", "-a", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
    for line in process.stdout:
        for key, pattern in patterns.items():
            matches = pattern.findall(line)
            if matches:
                counts[key] = counts.get(key, 0) + len(matches)
                tokens.setdefault(key, set()).update(matches)
    error = process.stderr.read()
    if process.wait():
        raise RuntimeError("strings failed: " + error.strip())
    return {"observed_marker_occurrences": counts,
            "observed_marker_tokens": {k: sorted(v)[:20] for k, v in tokens.items()},
            "limitation": "ASCII strings from the whole universal file, not isolated ARM64 code; markers can be unused, stale, dependency or other-slice content. They suggest provenance, not the active renderer/engine or iPad compatibility. Raw strings and developer paths are omitted."}


def compare_baseline(current_files, baseline_files):
    current = {f["path"]: f["sha256"] for f in current_files}
    previous = {f["path"]: f["sha256"] for f in baseline_files}
    return {"changed": sorted(p for p in current.keys() & previous.keys() if current[p] != previous[p]),
            "added": sorted(current.keys() - previous.keys()),
            "removed": sorted(previous.keys() - current.keys()),
            "limitation": "Hashes detect file changes only; unchanged hashes do not establish compatibility."}


def audit(app, manifest=None, sdk=None, baseline=None):
    app = Path(app).expanduser().resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        plist = plistlib.load(source)
    executable_name = plist["CFBundleExecutable"]
    if Path(executable_name).name != executable_name:
        raise ValueError("Bundle executable must be a basename")
    executable = app / "Contents/MacOS" / executable_name
    steam = app / "Contents/MacOS/libsteam_api.dylib"
    files, binaries = [], []
    sdk_path, sdk_reason = find_sdk(sdk)
    inventory = sdk_inventory(sdk_path) if sdk_path else None
    for path in (executable, steam):
        fingerprint = hash_file(path)
        relative = str(path.relative_to(app))
        architectures = run("lipo", "-archs", str(path)).strip().split()
        binary = {"path": relative, "architectures": architectures}
        if "arm64" in architectures:
            dependencies = parse_dependencies(run("otool", "-arch", "arm64", "-L", str(path)))
            imports = parse_imports(run("nm", "-arch", "arm64", "-u", "-m", str(path)))
            binary.update({"audited_architecture": "arm64", "dependencies": dependencies,
                           "undefined_imports": imports,
                           "build_versions": parse_build_versions(run("otool", "-arch", "arm64", "-l", str(path)))})
            if inventory:
                binary["sdk_comparison"] = compare_sdk(dependencies, imports, inventory)
        else:
            binary["arm64_analysis"] = "unverified: no arm64 slice"
        if fingerprint != hash_file(path):
            raise RuntimeError("File changed while tools ran: " + relative)
        files.append({"path": relative, **fingerprint})
        binaries.append(binary)
    manifest_path = Path(manifest).expanduser().resolve() if manifest else app.parents[2] / ("appmanifest_" + APP_ID + ".acf")
    manifest_info = {"status": "unverified", "reason": "Manifest not found"}
    if manifest_path.is_file():
        manifest_info = {"status": "observed", "selected_fields": selected_manifest(manifest_path.read_text()),
                         "privacy": "Only allowlisted game/build fields; account fields and full manifest omitted."}
    markers = static_markers(executable)
    for record in files:
        if hash_file(app / record["path"]) != {key: record[key] for key in ("size_bytes", "sha256")}:
            raise RuntimeError("File changed before audit completed: " + record["path"])
    report = {"schema_version": 1, "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "app_id": APP_ID, "app_path": str(app), "audit_mode": "read-only static inspection; no execution",
              "observed": {"bundle": {k: plist[k] for k in PLIST_KEYS if k in plist},
                           "steam_manifest": manifest_info, "files": files, "binaries": binaries,
                           "static_strings": markers},
              "sdk": {"path": str(sdk_path) if sdk_path else None, "selection": sdk_reason,
                      "metadata": sdk_metadata(sdk_path) if sdk_path else {},
                      "comparison_status": "static declaration candidates only" if inventory else "unverified",
                      **({k: inventory[k] for k in ("stub_count", "skipped_stubs", "targets")} if inventory else {})},
              "inferred": ["An arm64 Mac slice can avoid CPU translation, but still requires iPadOS platform, API and graphics adaptation.",
                           "OpenGL dependencies and winit/glutin markers motivate focused graphics/windowing investigation; markers alone do not identify the active renderer."],
              "unverified": ["iPad launch, rendering, input, audio, saves, performance and memory use",
                             "Steam authentication, ownership, achievements, cloud saves and account-policy compatibility on iPad",
                             "Completeness and ABI correctness of an AgePad-derived compatibility layer for this game",
                             "Compatibility after any future game or Steam update"],
              "assessment": "Investigation evidence only; no iPad compatibility or successful port is claimed."}
    if baseline:
        previous = json.loads(Path(baseline).read_text())
        report["baseline_comparison"] = compare_baseline(files, previous["observed"]["files"])
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Explicit path to your owned TeamfightManager2.app")
    parser.add_argument("--manifest", help="Optional appmanifest_3009300.acf (auto-detected beside steamapps/common)")
    parser.add_argument("--sdk", help="Optional local iPhoneOS SDK directory; otherwise discovered")
    parser.add_argument("--baseline", help="Previous audit JSON; report changed/added/removed executable hashes")
    parser.add_argument("--output", help="Write JSON here; otherwise stdout")
    args = parser.parse_args(argv)
    # Never let output overwrite game files or a previous baseline.
    if args.output:
        destination = Path(args.output).expanduser().resolve()
        app = Path(args.app).expanduser().resolve()
        if destination == app.parent or app.parent in destination.parents:
            parser.error("--output must be outside the game installation directory")
        if args.baseline and destination == Path(args.baseline).expanduser().resolve():
            parser.error("--output must not overwrite --baseline")
        manifest_path = Path(args.manifest).expanduser().resolve() if args.manifest else app.parents[2] / ("appmanifest_" + APP_ID + ".acf")
        if destination == manifest_path:
            parser.error("--output must not overwrite --manifest")
    try:
        result = audit(args.app, args.manifest, args.sdk, args.baseline)
        serialized = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(serialized)
            print("Saved read-only audit: " + str(destination), file=sys.stderr)
        else:
            print(serialized, end="")
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print("Audit failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
