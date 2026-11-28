"""Patch the measured Hariki HK anti-cheat report path in the v146 Ultra IPA.

This disables the dyld image callback registration and HK's auto-ban sender.
It does not establish that server-side or game-native checks are bypassed.
"""

from __future__ import annotations

import argparse
import hashlib
import zipfile
from pathlib import Path

SOURCE_SHA256 = "b74cdfb5a238bcee0eb6b6cf3e6fe263cf2c8d6bbb20f37b1490bf3b1bdaffe2"
HK_SHA256 = "2b4b5a6facc4196352f1ef9dde1fe89622bbf2df864be72472257eda639bbb31"
HK_MEMBER = "Payload/client.app/Frameworks/HK.framework/HK"
NOP = bytes.fromhex("1f2003d5")
RET = bytes.fromhex("c0035fd6")
PATCHES = (
    # __dyld_register_func_for_add_image callback registration.
    (0x4014, bytes.fromhex("a0c80194"), NOP),
    # HK report sender called from the measured detection branches.
    (0x537C, bytes.fromhex("fc6fbaa9"), RET),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_hk(data: bytes) -> bytes:
    if sha256(data) != HK_SHA256:
        raise ValueError("HK binary SHA-256 differs from the measured v146 Ultra build")
    out = bytearray(data)
    for offset, original, replacement in PATCHES:
        actual = bytes(out[offset : offset + len(original)])
        if actual != original:
            raise ValueError(f"HK bytes at 0x{offset:x}: expected {original.hex()}, got {actual.hex()}")
        out[offset : offset + len(original)] = replacement
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.output.resolve():
        parser.error("output must differ from source")
    if sha256(args.source.read_bytes()) != SOURCE_SHA256:
        parser.error("source IPA SHA-256 differs from the measured v146 Ultra build")

    with zipfile.ZipFile(args.source, "r") as src, zipfile.ZipFile(args.output, "w") as dst:
        if HK_MEMBER not in src.namelist():
            raise ValueError(f"missing {HK_MEMBER}")
        dst.comment = src.comment
        for info in src.infolist():
            data = src.read(info)
            if info.filename == HK_MEMBER:
                data = patch_hk(data)
            dst.writestr(info, data)

    with zipfile.ZipFile(args.output, "r") as result:
        hk = result.read(HK_MEMBER)
        for offset, _original, replacement in PATCHES:
            if hk[offset : offset + len(replacement)] != replacement:
                raise RuntimeError(f"post-check failed at HK 0x{offset:x}")
    print(f"patched {args.output}")
    print(f"patched HK SHA-256 {sha256(hk)}")
    print("rollback: use the original IPA unchanged")


if __name__ == "__main__":
    main()
