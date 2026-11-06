#!/usr/bin/env python3
"""Stage or verify the two pinned Steam stability fixes before final signing."""
import argparse
import hashlib
import json
from pathlib import Path

import patch_steam_queue as queue
import stage_steam_desktop_audio as audio

ROOT = Path(__file__).resolve().parents[1]
RECORD = "steam-runtime-fixes.json"
MARKER = "SteamRuntimeFixesIncomplete"
CLIENT = "steamclient.dylib"
TIER0 = "libtier0_s.dylib"
INPUT_LIBRARY_PINS = {CLIENT: audio.PIN, TIER0: queue.IMAGE_SHA256}
OUTPUT_LIBRARY_PINS = {
    CLIENT: "1e5da822f1abc9af5b37ba209ca2d75dbea23c5d29975bd1dd614f7be9cadc38",
    TIER0: "7a4c7a15407c79e795c3b83cee041a9c18d71e8415d56c22458bbb1d8a95cbbe",
    audio.FILE: "e7832e7a935b82b26fe7958dbee6792edd5fcc80b2ab14170a16395db29386cf",
}
AUDIO_SOURCE_SHA256 = "d9fb83d617165fad2a54e4a4c4b24c49458fe1020d9f73f56d7386c26dfd4efb"
STATUS = "staged_unsigned_steam_runtime_fixes"


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("Steam fix artifact must be a regular non-symlink file: " + path.name)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    result = {str(path.relative_to(ROOT)): digest(path) for path in (
        audio.SOURCE, Path(audio.__file__), Path(queue.__file__), Path(__file__))}
    if result["compat/steam/SteamDesktopAudio.c"] != AUDIO_SOURCE_SHA256:
        raise ValueError("Steam desktop-audio source differs from pinned compiled boundary provenance")
    return result


def plan_input(library_pins):
    if any(library_pins.get(name) != value for name, value in INPUT_LIBRARY_PINS.items()):
        raise ValueError("Online rebuild needs the exact reviewed pre-fix Steam client/tier0 input pins")
    if audio.FILE in library_pins:
        raise ValueError("Unexpected desktop-audio boundary in pre-fix Steam inputs")
    return {"input_library_pins": dict(INPUT_LIBRARY_PINS), "output_library_pins": dict(OUTPUT_LIBRARY_PINS),
            "source_hashes": source_hashes()}


def _audio_record(frameworks):
    client = frameworks / CLIENT
    dependencies, sections = audio.inspect(client.read_bytes())
    matches = [entry for entry in dependencies if entry["name"] == audio.TARGET]
    if len(matches) != 1 or matches[0]["ordinal"] != 13 or any(entry["name"] == audio.ORIGINAL for entry in dependencies):
        raise ValueError("Steam desktop HAL dependency/ordinal is inconsistent")
    command = matches[0]
    boundary = frameworks / audio.FILE
    boundary_dependencies, _ = audio.inspect(boundary.read_bytes())
    if [entry["name"] for entry in boundary_dependencies] != ["/usr/lib/libSystem.B.dylib"]:
        raise ValueError("Steam desktop HAL boundary gained native framework forwarding")
    exports = {line.split()[-1] for line in audio.run(["xcrun", "nm", "-gU", str(boundary)]).splitlines() if line.split()}
    if exports != audio.EXPORTS or audio.run(["xcrun", "otool", "-D", str(boundary)]).splitlines()[1:] != [audio.INSTALL_NAME]:
        raise ValueError("Steam desktop HAL boundary exports/install name differ")
    audio.verify_dyld_hal_bindings(client, "TFMSteamDesktopAudio")
    return {"schema_version": 1, "status": "steam_desktop_hal_unavailable_boundary_staged_requires_signing",
            "client": CLIENT, "input_sha256": INPUT_LIBRARY_PINS[CLIENT], "output_sha256": OUTPUT_LIBRARY_PINS[CLIENT],
            "file": audio.FILE, "sha256": OUTPUT_LIBRARY_PINS[audio.FILE], "size": boundary.stat().st_size,
            "install_name": audio.INSTALL_NAME, "source": "compat/steam/SteamDesktopAudio.c", "source_sha256": AUDIO_SOURCE_SHA256,
            "rebound_dependency": {"from": audio.ORIGINAL, "to": audio.TARGET, "ordinal": command["ordinal"]},
            "changed_metadata_range": {"offset": command["offset"] + command["name_offset"], "size": command["size"] - command["name_offset"]},
            "verified_exports": sorted(audio.EXPORTS), "client_sections": sections,
            "metadata_only": True, "all_sections_preserved": True, "all_other_bytes_preserved": True,
            "instructions_changed": False, "library_ordinals_preserved": True, "game_audio_modified": False,
            "vendor_code_executed": False, "device_accessed": False, "requires_final_signing": True,
            "policy": "Steam desktop HAL devices empty; default IDs unknown; other reads/set unsupported; no native HAL forwarding"}


def _expected_record(bundle):
    frameworks = bundle / "Frameworks"
    for name, pin in OUTPUT_LIBRARY_PINS.items():
        if digest(frameworks / name) != pin:
            raise ValueError("Steam runtime fix output differs from reviewed unsigned bytes: " + name)
    return {"schema_version": 1, "status": STATUS,
            "input_library_pins": dict(INPUT_LIBRARY_PINS), "output_library_pins": dict(OUTPUT_LIBRARY_PINS),
            "source_hashes": source_hashes(),
            "steam_queue_guard": {"original": INPUT_LIBRARY_PINS[TIER0], "guarded": OUTPUT_LIBRARY_PINS[TIER0], "offset": hex(queue.OFFSET)},
            "steam_desktop_audio": _audio_record(frameworks)}


def verify(bundle: Path) -> dict:
    """Read-only verification; signed or partially staged images are rejected."""
    bundle = Path(bundle)
    if bundle.is_symlink() or not bundle.is_dir() or (bundle / "Frameworks").is_symlink():
        raise ValueError("Need a regular unsigned app bundle")
    if (bundle / MARKER).exists() or (bundle / MARKER).is_symlink():
        raise ValueError("Steam runtime fix stage is incomplete")
    path = bundle / RECORD
    digest(path)
    expected = _expected_record(bundle)
    if json.loads(path.read_text()) != expected:
        raise ValueError("Steam runtime fix record/provenance is inconsistent with reviewed bytes")
    return expected


def stage_or_verify(bundle: Path) -> dict:
    """Apply both fixes once, or strictly verify a previously fixed unsigned base."""
    bundle = Path(bundle)
    if bundle.is_symlink() or not bundle.is_dir() or (bundle / "Frameworks").is_symlink():
        raise ValueError("Need a regular unsigned app bundle")
    record, marker = bundle / RECORD, bundle / MARKER
    if record.exists() or record.is_symlink():
        return verify(bundle)
    if marker.exists() or marker.is_symlink():
        raise ValueError("Steam runtime fix stage is incomplete")
    frameworks = bundle / "Frameworks"
    if (frameworks / audio.FILE).exists() or (frameworks / audio.FILE).is_symlink():
        raise ValueError("Desktop-audio boundary exists without fix provenance")
    plan_input({name: digest(frameworks / name) for name in INPUT_LIBRARY_PINS})
    originals = {name: (frameworks / name).read_bytes() for name in INPUT_LIBRARY_PINS}
    marker.write_text("Steam stability staging incomplete; do not sign/install.\n")
    try:
        guarded = queue.guard_queue(frameworks / TIER0)
        staged_audio = audio.stage_audio(frameworks)
        expected = _expected_record(bundle)
        if guarded != expected["steam_queue_guard"] or staged_audio != expected["steam_desktop_audio"]:
            raise ValueError("Steam fix staging output/provenance differs from reviewed result")
        record.write_text(json.dumps(expected, indent=2) + "\n")
        marker.unlink()
        return verify(bundle)
    except BaseException:
        for name, data in originals.items():
            (frameworks / name).write_bytes(data)
        (frameworks / audio.FILE).unlink(missing_ok=True)
        record.unlink(missing_ok=True)
        marker.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(stage_or_verify(args.bundle), indent=2))
