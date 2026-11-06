"""Guard the verified ARM64 Steam tier0 queue pop before copying a missing payload."""
from hashlib import sha256

IMAGE_SHA256 = "2a92ed02b2f62a1705046870bfa563e07a2f6b9fa4268808f3416e1f65c0855d"
OFFSET = 0xee9c
ORIGINAL = bytes.fromhex("ea0240f9 eb1340f9 5f010beb")
# cbz x8, empty_return; ldr x10,[x23]; cmp x10,x24
# x24 holds the same head snapshot previously reloaded from the stack into x11.
GUARDED = bytes.fromhex("a80300b4 ea0240f9 5f0118eb")


def guard_queue(path):
    image = path.read_bytes()
    if sha256(image).hexdigest() != IMAGE_SHA256 or image[OFFSET:OFFSET+len(ORIGINAL)] != ORIGINAL:
        raise ValueError("Unrecognized Steam tier0 image or queue instructions")
    guarded = image[:OFFSET] + GUARDED + image[OFFSET+len(ORIGINAL):]
    path.write_bytes(guarded)
    return {"original": IMAGE_SHA256, "guarded": sha256(guarded).hexdigest(), "offset": hex(OFFSET)}
