#!/usr/bin/env python3
"""Prepare owner signing, sign a copy, and install without deleting existing data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "kit/tools"))
from sign_probe import sign_copy, validate_bundle_id, verify_signed


def configure_xcode():
    # Honor an explicitly selected Xcode, including beta/nonstandard installs.
    if not os.environ.get("DEVELOPER_DIR"):
        selected = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        if selected.endswith("CommandLineTools") and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
            os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"


def prepare_signing(args):
    validate_bundle_id(args.bundle_id)
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        raise ValueError("--team must be your 10-character Apple team ID shown in Xcode")
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.device):
        raise ValueError("--device must be the iPad UDID, not its name or a devicectl connection UUID")
    work = args.work.resolve()
    if work.exists():
        raise ValueError("--work must be a new private directory; use a new one when renewing")
    project = work / "TFM2PADSigning.xcodeproj"
    project.mkdir(parents=True)
    (work / "main.m").write_text('#import <UIKit/UIKit.h>\n@interface SigningApp : UIResponder <UIApplicationDelegate>\n@end\n@implementation SigningApp\n@end\nint main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"SigningApp"); } }\n')
    # A tiny independent app obtains a profile for the SAME final identifier.
    # It is built only: never run/install it over an existing game container.
    settings = f'''SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 15.0;
        CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "Apple Development";
        DEVELOPMENT_TEAM = {args.team}; PRODUCT_BUNDLE_IDENTIFIER = {args.bundle_id};
        PRODUCT_NAME = TFM2PADSigning; TARGETED_DEVICE_FAMILY = 2;
        GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES;
        OTHER_LDFLAGS = "-framework UIKit -framework Foundation"; ALWAYS_SEARCH_USER_PATHS = NO;
        CLANG_ENABLE_OBJC_ARC = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0;'''
    (project / "project.pbxproj").write_text('''// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56;
objects = {
A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 1600;}; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = A00000000000000000000003; productRefGroup = A00000000000000000000004; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000005);};
A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000006); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000007, A00000000000000000000004); sourceTree = "<group>";};
A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000008); name = Products; sourceTree = "<group>";};
A00000000000000000000005 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000009; buildPhases = (A0000000000000000000000A, A0000000000000000000000B); buildRules = (); dependencies = (); name = TFM2PADSigning; productName = TFM2PADSigning; productReference = A00000000000000000000008; productType = "com.apple.product-type.application";};
A00000000000000000000006 = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug;};
A00000000000000000000007 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = "<group>";};
A00000000000000000000008 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TFM2PADSigning.app; sourceTree = BUILT_PRODUCTS_DIR;};
A00000000000000000000009 = {isa = XCConfigurationList; buildConfigurations = (A0000000000000000000000C); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;};
A0000000000000000000000A = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A0000000000000000000000D); runOnlyForDeploymentPostprocessing = 0;};
A0000000000000000000000B = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
A0000000000000000000000C = {isa = XCBuildConfiguration; buildSettings = {''' + settings + '''}; name = Debug;};
A0000000000000000000000D = {isa = PBXBuildFile; fileRef = A00000000000000000000007;};
}; rootObject = A00000000000000000000001; }
''')
    scheme_dir = project / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True)
    (scheme_dir / "TFM2PADSigning.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000005" BuildableName="TFM2PADSigning.app" BlueprintName="TFM2PADSigning" ReferencedContainer="container:TFM2PADSigning.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"/><ProfileAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Debug" revealArchiveInOrganizer="YES"/></Scheme>
''')
    if args.project_only:
        print(f"Created {project}; build with Product > Build in Xcode. Do not Run the signing helper.")
        return
    print("Xcode may create/update your development certificate, App ID and device profile. No app will be installed.", flush=True)
    subprocess.run(["xcodebuild", "-project", str(project), "-scheme", "TFM2PADSigning", "-configuration", "Debug",
        "-destination", "id=" + args.device, "-derivedDataPath", str(work / "DerivedData"),
        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"], check=True)
    print(f"Signing input: {work / 'DerivedData/Build/Products/Debug-iphoneos/TFM2PADSigning.app'}")


def devicectl(args, output):
    subprocess.run(["xcrun", "devicectl", *args, "--timeout", "300", "--json-output", str(output)], check=True)
    result = json.loads(output.read_text())
    if result.get("info", {}).get("outcome") != "success":
        raise ValueError(f"Device command did not report success; see {output}")
    return result.get("result", {})


def tree_hashes(root):
    if not root.is_dir():
        raise ValueError(f"Backup directory was not received: {root}")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("Unexpected symbolic link in device backup")
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            result[path.relative_to(root).as_posix()] = digest.hexdigest()
    return result


SAVE_PATH = "Library/Application Support/com.TeamSamoyed.TeamfightManager2"


def save_directory_exists(args, destination, tag):
    """Walk successful parent listings: an error is never treated as no saves."""
    parent = ""
    for index, component in enumerate(SAVE_PATH.split("/")):
        command = ["device", "info", "files", "--device", args.device, "--domain-type", "appDataContainer",
                   "--domain-identifier", args.bundle_id, "--no-recurse"]
        if parent:
            command.extend(["--subdirectory", parent])
        listing = devicectl(command, destination / f"{tag}-list-{index}.json")
        files = listing.get("files")
        if not isinstance(files, list) or any(not isinstance(item, dict) or not isinstance(item.get("name"), str) for item in files):
            raise ValueError("Unrecognized file-list JSON; cannot establish whether saves exist")
        found = next((item for item in files if item["name"] == component), None)
        if found is None:
            return False
        resources = found.get("resources", {})
        if resources.get("isDirectory") is not True or resources.get("isSymbolicLink") is not False:
            raise ValueError("Save path contains an unexpected file or symbolic link")
        parent = component if not parent else parent + "/" + component
    return True


def snapshot(args, destination, tag):
    present = save_directory_exists(args, destination, tag)
    hashes = {}
    if present:
        folder = destination / tag
        devicectl(["device", "copy", "from", "--device", args.device, "--domain-type", "appDataContainer",
            "--domain-identifier", args.bundle_id, "--source", SAVE_PATH, "--destination", str(folder)],
            destination / f"{tag}-copy.json")
        hashes = tree_hashes(folder)
    result = {"save_path": SAVE_PATH, "present": present, "sha256": hashes}
    (destination / f"{tag}-hashes.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def known_existing_app(existing, args, device_identifier):
    if existing.get("executableName") == "TFM2Probe":
        return "game"
    if existing.get("executableName") == "TFM2PADSigning" or existing.get("name") == "TFM2PADSigning":
        return "helper"
    if args.previous_install:
        receipt = json.loads(args.previous_install.read_text())
        signed = json.loads((args.previous_install.parent / "signing-check.json").read_text())
        if (receipt.get("info", {}).get("outcome") == "success" and
            receipt.get("result", {}).get("deviceIdentifier") == device_identifier and
            any(item.get("bundleID") == args.bundle_id for item in receipt.get("result", {}).get("installedApplications", [])) and
            signed.get("bundle_id") == args.bundle_id and signed.get("team") == args.team):
            return "game"
    raise ValueError("An app already owns this bundle ID and cannot be identified as this game. Use its previous toolkit --previous-install receipt, or choose a unique ID for a new installation. No existing app was replaced")


def install(args):
    validate_bundle_id(args.bundle_id)
    app = args.app.resolve(strict=True)
    # Every install rechecks the ACTUAL signature and current profile expiry.
    signed = verify_signed(app, bundle_id=args.bundle_id, team=args.team, device=args.device)
    backup = args.backup.resolve()
    if backup.exists() or backup == app or app in backup.parents:
        raise ValueError("--backup must be a new private directory outside the signed app")
    backup.mkdir(parents=True)
    apps = devicectl(["device", "info", "apps", "--device", args.device, "--include-all-apps"], backup / "apps-before.json")
    entries = apps.get("apps")
    if not isinstance(entries, list) or any(not isinstance(item, dict) or not isinstance(item.get("bundleIdentifier"), str) for item in entries):
        raise ValueError("Unrecognized installed-app JSON; refusing installation without a reliable update check")
    existing = next((item for item in entries if item["bundleIdentifier"] == args.bundle_id), None)
    kind = known_existing_app(existing, args, apps.get("deviceIdentifier")) if existing is not None else None
    if existing is not None and not args.game_closed:
        raise ValueError("Close the game on the iPad and rerun with --game-closed and a new --backup directory")
    before = snapshot(args, backup, "before") if existing is not None else None
    if kind == "helper" and before["present"]:
        raise ValueError("The helper ID contains game saves; use the previous game installation receipt to identify it")
    (backup / "signing-check.json").write_text(json.dumps(signed, indent=2) + "\n")
    # Always update in place; no uninstall, launch, container deletion or account migration.
    receipt = devicectl(["device", "install", "app", "--device", args.device, str(app)], backup / "install.json")
    installed = receipt.get("installedApplications", [])
    if not any(item.get("bundleID") == args.bundle_id for item in installed):
        raise ValueError("Installation returned no receipt for the expected app ID; inspect install.json")
    if before is not None:
        after = snapshot(args, backup, "after")
        changed = [path for path, digest in before["sha256"].items() if after["sha256"].get(path) != digest]
        if before["present"] and not after["present"]:
            changed.append("<save directory missing>")
        if changed:
            (backup / "changed-files.json").write_text(json.dumps(changed, indent=2) + "\n")
            raise ValueError("Installation completed but existing save files differ. Do not launch; retain the before backup and inspect changed-files.json")
        print("Installed update; all pre-existing game-save file hashes match. App was not launched.")
    else:
        print("Installed new app. App was not launched. No existing container used this bundle ID.")
    print(f"Private receipt/backup: {backup}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare-signing", help="Create/build a tiny Xcode project to obtain your own profile; never install it")
    prepare.add_argument("--work", required=True, type=Path)
    prepare.add_argument("--project-only", action="store_true", help="Create project for manual Xcode Product > Build; do not contact Apple")
    sign = commands.add_parser("sign", help="Sign a fresh copy of your unsigned app; never install it")
    sign.add_argument("--app", required=True, type=Path)
    sign.add_argument("--output", required=True, type=Path)
    selection = sign.add_mutually_exclusive_group(required=True)
    selection.add_argument("--xcode-app", type=Path, help="Built signing helper .app containing embedded.mobileprovision")
    selection.add_argument("--profile", type=Path, help="Your existing .mobileprovision file")
    sign.add_argument("--identity", help="Optional certificate SHA-1 to disambiguate matching identities")
    device_install = commands.add_parser("install", help="Back up existing game saves and update in place; never launch or uninstall")
    device_install.add_argument("--app", required=True, type=Path)
    device_install.add_argument("--backup", required=True, type=Path)
    device_install.add_argument("--previous-install", type=Path, help="Prior toolkit install.json receipt, with its sibling signing-check.json, for identifying updates")
    device_install.add_argument("--game-closed", action="store_true", help="Confirm you have closed the game for a consistent save backup")
    for command in (prepare, sign, device_install):
        command.add_argument("--bundle-id", required=True, help="Your unique final bundle ID; keep it for renewals/updates")
        command.add_argument("--team", required=True, help="Your Apple team ID from Xcode; keep it for updates")
        command.add_argument("--device", required=True, help="Provisioned iPad UDID from Xcode Devices and Simulators")
    args = parser.parse_args()
    try:
        configure_xcode()
        if args.command == "prepare-signing":
            prepare_signing(args)
        elif args.command == "sign":
            profile = args.profile if args.profile else args.xcode_app / "embedded.mobileprovision"
            result = sign_copy(args.app, args.output, profile_path=profile, bundle_id=args.bundle_id,
                team=args.team, device=args.device, identity=args.identity)
            print(f"Verified signed app: {args.output}\nProfile expires: {result['profile_expires']}\nNo app installed.")
        else:
            install(args)
    except (ValueError, KeyError, IndexError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{args.command} failed: {error}\nNo uninstall, launch, or automatic save restoration was performed. Keep all existing apps and backups.\n")


if __name__ == "__main__":
    main()
