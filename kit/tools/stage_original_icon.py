#!/usr/bin/env python3
"""Compile the purchased Mac app's original icon into a private iPad bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage_original_icon(source_app, bundle, env=None):
    source_app, bundle = Path(source_app).resolve(strict=True), Path(bundle).resolve(strict=True)
    if bundle == source_app or source_app in bundle.parents:
        raise ValueError("Icon destination must be outside the original game")
    info_path = bundle / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "org.tfm2pad.staging":
        raise ValueError("Only the private TFM2 iPad bundle is supported")
    original_info = plistlib.loads((source_app / "Contents/Info.plist").read_bytes())
    name = original_info.get("CFBundleIconFile")
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("Original game must name a local icon resource")
    if not name.endswith(".icns"):
        name += ".icns"
    resource = (source_app / "Contents/Resources" / name).resolve(strict=True)
    resource.relative_to(source_app)
    before = sha(resource)
    if (bundle / "Assets.car").exists() or (bundle / "original-icon-stage.json").exists():
        raise ValueError("Icon assets already present; use a fresh bundle")
    env = env or dict(os.environ)
    with tempfile.TemporaryDirectory(prefix="tfm-original-icon-", dir=bundle.parent) as directory:
        work = Path(directory)
        iconset = work / "Original.iconset"
        subprocess.run(["iconutil", "--convert", "iconset", "--output", str(iconset), str(resource)], check=True, env=env)
        image = iconset / "icon_512x512@2x.png"
        if not image.is_file():
            raise ValueError("Original 1024px icon is missing; no replacement artwork will be synthesized")
        catalog = work / "Assets.xcassets"
        appicon = catalog / "AppIcon.appiconset"
        appicon.mkdir(parents=True)
        shutil.copyfile(image, appicon / "Original.png")
        (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
        (appicon / "Contents.json").write_text(json.dumps({"images": [
            {"filename": "Original.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        ], "info": {"author": "xcode", "version": 1}}))
        partial = work / "icon-info.plist"
        result = subprocess.run(["xcrun", "actool", "--compile", str(bundle), "--platform", "iphoneos",
            "--minimum-deployment-target", str(info.get("MinimumOSVersion", "15.0")),
            "--target-device", "ipad", "--app-icon", "AppIcon",
            "--output-partial-info-plist", str(partial), "--output-format", "human-readable-text",
            str(catalog)], env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("Icon compilation failed:\n" + result.stdout + result.stderr)
        icon_info = plistlib.loads(partial.read_bytes())
        if not (bundle / "Assets.car").is_file() or not icon_info.get("CFBundleIcons~ipad"):
            raise ValueError("Asset compiler did not produce the required iPad icon")
        info.update(icon_info)
        info_path.write_bytes(plistlib.dumps(info))
        artifacts = [bundle / "Assets.car", *bundle.glob("AppIcon*.png")]
        report = {"schema_version": 1, "source_resource": "Contents/Resources/" + name,
            "source_icns_sha256": before, "extracted_original_png_sha256": sha(image),
            "artwork_changed": False, "compiler": "Apple actool", "icon_name": "AppIcon",
            "artifacts": {p.name: sha(p) for p in artifacts}, "plist_keys": icon_info}
    if sha(resource) != before:
        raise ValueError("Original icon changed during staging")
    (bundle / "original-icon-stage.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--probe-app", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(stage_original_icon(args.app, args.probe_app), indent=2))
