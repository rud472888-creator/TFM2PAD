"""Shared Steam IPC artifact construction/validation; never load vendor code."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_NAMES = ("SteamLaunchPolicy.h", "SteamIPC.m", "SteamIPC.h", "SteamIPCProfile.json", "SteamSemaphoreCompat.c", "SteamSemaphoreCompat.h")
FILE = "TFMSteamIPC.dylib"
PROFILE = "SteamIPCProfile.json"
INSTALL_NAME = "@rpath/" + FILE
SEMAPHORE_EXPORTS = {"_semget", "_semop", "_semctl", "_TFMSteamSemaphoreCopyStats"}
EXPORTS = {"_TFMSteamIPCProbe", "_TFMSteamIPCProbeAfterLogon", "_TFMSteamIPCPrepareForGame", "_TFMSteamIPCStatus", "_bootstrap_check_in", "_bootstrap_look_up", "_exit", "__exit", "_signal"} | SEMAPHORE_EXPORTS


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return {"compat/steam/" + name: sha(ROOT / "compat/steam" / name) for name in SOURCE_NAMES}


def profile(path):
    value = json.loads(path.read_text())
    helper, sdk = value.get("helper", {}), value.get("sdk", {})
    helper_signal = helper.get("process_sigterm_registration")
    if (value.get("schema_version") != 1 or helper.get("original_lc_main_entryoff") != 6888
            or helper.get("image") != "TFMSteamIPCHelper.dylib" or sdk.get("image") != "libsteam_api.dylib"
            or helper.get("original_arm64_sha256") != "c0093a41b685bd633b585e9ca1cbe40c7fa9b43397fb6e254019953b1a99936b"
            or helper.get("uuid") != "e4d6996719f233189427f21f8eda03e1"
            or helper.get("entry_first64_sha256") != "6c78a806a3358e36196a96af00c740d71ae8e23df5a5feffa8aa715b30ec4883"
            or helper.get("text_sha256") != "7fa3e7c65fcec87df8a72d7d5c0a0400a8e394fb74c294268019f70270d48df2"
            or helper_signal != {"signal": 15, "handler_offset": 0x1acc, "callsite_offset": 0x1b68, "return_offset": 0x1b6c,
                "registration_first16_sha256": "4da776cb584b1fa6e21600a39c1bc0736dc02288fae754e3f7cd79a4c3a13d1c",
                "handler_first28_sha256": "e8333f9dd767f135db0782ae102a7968361978c83a58481f476ac75addc050d9"}
            or sdk.get("original_universal_sha256") != "363ab50ce9bf4680d8ddb8c6142e566854803f831769fab0428867b9994d0520"
            or sdk.get("uuid") != "fca0302280d73c019d1242b887a94e65" or sdk.get("init_offset") != 0x38c8
            or sdk.get("init_export") != "SteamInternal_SteamAPI_Init"
            or sdk.get("init_first64_sha256") != "19fdea73257a51133d7751403b41b6b691ba77e3ea8da8a8e06390f4023ffea1"
            or value.get("instructions_changed") is not False or value.get("authentication_or_ownership_claimed") is not False):
        raise ValueError("Shared Steam IPC profile differs from audited original helper/SDK metadata")
    return value


def inspect(path, run):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Shared Steam IPC dylib must be a regular file")
    if run(["xcrun", "lipo", "-archs", str(path)]).split() != ["arm64"]:
        raise ValueError("Shared Steam IPC requires only ARM64")
    loads = run(["xcrun", "otool", "-l", str(path)])
    command = re.search(r"cmd LC_BUILD_VERSION\b(?:(?!Load command).)*", loads, re.S)
    if not command or not re.search(r"\bplatform (?:2|IOS)\b", command[0]):
        raise ValueError("Shared Steam IPC requires iOS-device platform")
    if run(["xcrun", "otool", "-D", str(path)]).splitlines()[1:] != [INSTALL_NAME]:
        raise ValueError("Shared Steam IPC install name changed")
    exported = {line.split()[-1] for line in run(["xcrun", "nm", "-gU", str(path)]).splitlines() if line.split()}
    if EXPORTS - exported:
        raise ValueError("Shared Steam IPC required exports missing")
    return sorted(exported)


def build(output, sdk, cache, run):
    expected = sources()
    profile(ROOT / "compat/steam" / PROFILE)
    path = output / FILE
    semaphore_object = output / "SteamSemaphoreCompat.o"
    run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", str(sdk),
         "-miphoneos-version-min=15.0", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
         str(ROOT / "compat/steam/SteamSemaphoreCompat.c"), "-o", str(semaphore_object)])
    run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", str(sdk),
         "-miphoneos-version-min=15.0", "-dynamiclib", "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror",
         "-Wno-deprecated-declarations", "-fmodules-cache-path=" + str(cache), "-framework", "Foundation",
         "-Wl,-install_name," + INSTALL_NAME, str(ROOT / "compat/steam/SteamIPC.m"), str(semaphore_object), "-o", str(path)])
    exports = inspect(path, run)
    shutil.copy2(ROOT / "compat/steam" / PROFILE, output / PROFILE)
    if expected != sources() or sha(output / PROFILE) != expected["compat/steam/" + PROFILE]:
        raise RuntimeError("Shared Steam IPC sources/profile changed during compilation")
    return {"schema_version": 1, "status": "built_shared_ipc_not_executed", "provider": "SteamIPCShared",
            "file": FILE, "sha256": sha(path), "size": path.stat().st_size, "install_name": INSTALL_NAME,
            "profile_file": PROFILE, "profile_sha256": sha(output / PROFILE), "source_hashes": expected,
            "direct_implemented_exports": sorted(EXPORTS), "all_direct_exports": exports,
            "embedded_helper_signal_policy": {"export": "_signal", "pinned_helper_sigterm_registration": "SIG_ERR/ENOTSUP",
                "other_signal_requests": "native_passthrough", "host_disposition_changed": False},
            "source_hashes_verified_before_and_after": True, "client_executed": False,
            "app_local_sysv_semaphores": {"exports": sorted(SEMAPHORE_EXPORTS), "state_image": FILE,
                "set_limit": 256, "semaphores_per_set_limit": 256, "operation_count_limit": 256, "value_max": 32767,
                "scope": "One process-local shared namespace with real pthread blocking, atomic transactions and removal/cancellation cleanup",
                "limitations": ["No fork or cross-process sharing", "SEM_UNDO has process-lifetime-only semantics; thread exit does not undo",
                    "IPC_SET returns ENOTSUP", "Signal-driven EINTR/arbitrary invalid user-pointer kernel validation not implemented"]},
            "scope": "Single app-local Mach-service and SysV semaphore state; original helper and SDK calls require explicit diagnostic mode"}


def validate(directory, record):
    directory = Path(directory).resolve(strict=True)
    if (record.get("schema_version") != 1 or record.get("status") != "built_shared_ipc_not_executed"
            or record.get("file") != FILE or record.get("install_name") != INSTALL_NAME
            or record.get("profile_file") != PROFILE or not record.get("source_hashes_verified_before_and_after")
            or record.get("source_hashes") != sources()):
        raise ValueError("Shared Steam IPC build/source/header/profile provenance is invalid or stale")
    dylib, metadata = directory / FILE, directory / PROFILE
    if dylib.is_symlink() or sha(dylib) != record["sha256"] or dylib.stat().st_size != record["size"]:
        raise ValueError("Shared Steam IPC dylib changed after build")
    if metadata.is_symlink() or sha(metadata) != record["profile_sha256"] or sha(metadata) != record["source_hashes"]["compat/steam/" + PROFILE]:
        raise ValueError("Shared Steam IPC profile changed after build")
    profile(metadata)
    env = dict(os.environ)
    def run(argv):
        return subprocess.check_output(argv, env=env, text=True)
    exported = inspect(dylib, run)
    if exported != record["all_direct_exports"] or set(record["direct_implemented_exports"]) != EXPORTS:
        raise ValueError("Shared Steam IPC export provenance differs from actual image")
    return dylib, metadata


def validate_reexport_order(paths):
    if INSTALL_NAME not in paths or "/usr/lib/libSystem.B.dylib" not in paths or paths.index(INSTALL_NAME) >= paths.index("/usr/lib/libSystem.B.dylib"):
        raise ValueError("Shared Steam IPC must be reexported before real libSystem")
