#!/usr/bin/env python3
"""Generate private facility build inputs from the purchaser's base-game data.

No DLL, network, account state, or save is needed. Call
generate_facility_inputs(game_data, private_management_directory) after copying
the source crate into a private build directory and before invoking Cargo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

RECORD_KIND = "data_setting"
RECORD_KEY = "asset/base/setting/data_setting"
RECORD_SHA256 = "ad00da3355abe764b31712eafac27923318f7f91400409e39c51f132a0f60426"
FIELDS = ("dev_cost", "unit_cost", "default_margin", "demand_pct")
PRODUCT_COUNT = 10
PUBLIC_KIT = Path(__file__).resolve().parents[1] / "kit"


def extract_facility_rows(game_data: Path) -> list[tuple[int, int, int, int]]:
    """Read only the pinned settings payload; preserve serialized product order."""
    game_data = Path(game_data)
    with game_data.open("rb") as stream:
        file_size = game_data.stat().st_size

        def read_exact(size):
            data = stream.read(size)
            if len(data) != size:
                raise ValueError("Truncated game-data record")
            return data

        def number():
            return struct.unpack("<I", read_exact(4))[0]

        def label():
            size = number()
            if size > 8192:
                raise ValueError("Unexpected game-data record name")
            return read_exact(size).decode("utf-8", errors="strict")

        count = number()
        if not 0 < count <= 100_000:
            raise ValueError("Unexpected game-data record count")
        for _ in range(count):
            kind, key, length = label(), label(), number()
            if length > file_size - stream.tell():
                raise ValueError("Game-data record extends beyond the input")
            if kind != RECORD_KIND or key != RECORD_KEY:
                stream.seek(length, 1)
                continue
            if length > 2_000_000:
                raise ValueError("Unexpected facility settings payload size")
            payload = read_exact(length)
            if hashlib.sha256(payload).hexdigest() != RECORD_SHA256:
                raise ValueError("Unsupported facility settings; input pins are never updated automatically")
            settings = json.loads(payload)["merchandise_product_setting"]
            products = settings["products"]
            if not isinstance(products, list) or len(products) != PRODUCT_COUNT:
                raise ValueError("Unexpected facility product count")
            rows = []
            for product in products:
                values = tuple(product[field] for field in FIELDS)
                if any(type(value) is not int or not 0 <= value < 2**64 for value in values):
                    raise ValueError("Facility product values must be unsigned integers")
                rows.append(values)
            return rows
    raise ValueError("Required facility settings are absent from the purchased game")


def generate_facility_inputs(game_data: Path, management_directory: Path) -> dict:
    """Write one fresh Rust include in a private copied crate; return metadata."""
    directory = Path(management_directory).resolve(strict=True)
    public = PUBLIC_KIT.resolve()
    if directory == public or public in directory.parents:
        raise ValueError("Generated game data belongs in a private build directory outside kit/")
    source = Path(game_data).resolve(strict=True)
    if directory == source.parent or source.parent in directory.parents or directory in source.parents:
        raise ValueError("Keep generated build inputs separate from the original game-data directory")
    destination = directory / "src/facility_products.rs"
    if not destination.parent.is_dir() or destination.parent.resolve().parent != directory:
        raise ValueError("Expected a copied management crate with a local src/ directory")
    if destination.resolve() == source:
        raise ValueError("Generated input must not replace source game data")
    rows = extract_facility_rows(source)
    text = "// Private generated game data; do not redistribute.\n"
    text += "pub const PRODUCT: [(u64, u64, u64, u64); 10] = [\n"
    text += "".join("    (" + ", ".join(map(str, row)) + "),\n" for row in rows)
    text += "];\n"
    with destination.open("x") as stream:
        stream.write(text)
    return {"status": "generated_private_facility_inputs", "product_count": len(rows),
            "source_record": RECORD_KEY, "source_payload_sha256": RECORD_SHA256,
            "generated_file": "src/facility_products.rs",
            "generated_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-data", required=True, type=Path)
    parser.add_argument("--management-directory", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(generate_facility_inputs(args.game_data, args.management_directory), indent=2))


if __name__ == "__main__":
    main()
