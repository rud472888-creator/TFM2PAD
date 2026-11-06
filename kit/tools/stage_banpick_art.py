#!/usr/bin/env python3
"""Prepare the linked illustration release for the iPad view mod (private staging)."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import re
from zipfile import ZipFile

from PIL import Image

PACK_SHA = 'd659d02c92af0034166f3c932ae2d5ce95eebf2e19ad77b011dc49c57a634a3b'


def stage(archive, output, width):
    if not 320 <= width <= 1140:
        raise ValueError("Unsupported card width")
    with archive.open("rb") as src:
        digest = hashlib.file_digest(src, "sha256").hexdigest()
    # Use the original release, not filenames from arbitrary archives.
    if digest != PACK_SHA:
        raise ValueError("Unreviewed illustration archive")
    output.mkdir(exist_ok=False)
    marker = output / "INCOMPLETE"
    marker.write_text("Preparing art\n")
    pattern = re.compile(r"tfm2_banpick_illust/illust/(blue|red|red_noflip)/([a-z0-9_]+)(?:-(\d+))?\.png")
    with ZipFile(archive) as z:
        entries = z.infolist()
        if len(entries) != 473:
            raise ValueError("Unexpected file count")
        def convert(entry):
            match = pattern.fullmatch(entry.filename)
            if not match or entry.file_size > 16 * 1024 * 1024:
                raise ValueError("Unexpected archive member: " + entry.filename)
            side, name, alternate = match.groups()
            rel = Path("illust",side,Path(entry.filename).name)
            path = output / rel
            path.parent.mkdir(parents=True,exist_ok=True)
            raw = z.read(entry)
            with Image.open(io.BytesIO(raw)) as img:
                img.thumbnail((width,width),Image.Resampling.LANCZOS)
                img.save(path,format="PNG",compress_level=4)
            source = "asset/tfm2_view_plus_ios/" + str(rel.with_suffix(""))
            return side,name,int(alternate or 0),source
        with ThreadPoolExecutor(max_workers=5) as pool:
            rows = list(pool.map(convert, entries))
    manifest = {"champions":{}, "red":{}, "red_noflip":{}}
    for side, name, variant, source in sorted(rows):
        mapping = manifest["champions" if side=="blue" else side]
        mapping.setdefault(name,[]).append(source)
    (output / "illust-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    marker.unlink()
    return {s:sum(map(len,v.values())) for s,v in manifest.items()}


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive",type=Path)
    parser.add_argument("output",type=Path)
    parser.add_argument("--width",type=int,default=640)
    args=parser.parse_args()
    print(stage(args.archive,args.output,args.width))
