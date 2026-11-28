"""Embed the measured RosModV2UI dylib in the patched v146 Ultra IPA."""

from __future__ import annotations

import argparse
import hashlib
import struct
import zipfile
from pathlib import Path

SOURCE_SHA256 = "6fd4b4a74790ecb5435caa9ccb6cc6fe04989468c48ba6b0bff630a6ec56fd4b"
DYLIB_SHA256 = "2ec429aabef3012a300d54bc1b53367d470b01cd05a60c3bdf083af683d80261"
CLIENT_SHA256 = "27ebb92b0d774bef1d56c21fccf339a58be101ca835c7eb710b4ef94b5c47fce"
CLIENT_MEMBER = "Payload/client.app/client"
DYLIB_MEMBER = "Payload/client.app/Frameworks/RosModV2UI.dylib"
LOAD_NAME = b"@executable_path/Frameworks/RosModV2UI.dylib\0"
LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_names(data: bytes) -> list[str]:
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end = 32 + sizeofcmds
    offset = 32
    names = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("invalid Mach-O load command range")
        if cmd in (0xC, 0xD, 0x18, 0x1F, 0x80000018):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + name_offset : offset + size].split(b"\0", 1)[0]
            names.append(name.decode("utf-8", "replace"))
        offset += size
    if offset != end:
        raise ValueError("Mach-O command sizes do not match sizeofcmds")
    return names


def patch_client(client: bytes) -> bytes:
    if digest(client) != CLIENT_SHA256:
        raise ValueError("client digest differs from the measured v146 Ultra build")
    if struct.unpack_from("<I", client, 0)[0] != MH_MAGIC_64 or struct.unpack_from("<I", client, 4)[0] != CPU_TYPE_ARM64:
        raise ValueError("client is not arm64 Mach-O")
    if LOAD_NAME.decode().strip("\0") in load_names(client):
        raise ValueError("dylib load command is already present")
    ncmds, sizeofcmds = struct.unpack_from("<II", client, 16)
    insert_at = 32 + sizeofcmds
    size = (24 + len(LOAD_NAME) + 7) & ~7
    if insert_at + size > 0x4000 or any(client[insert_at : insert_at + size]):
        raise ValueError("no verified zero padding for new load command")
    command = struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 0, 0, 0) + LOAD_NAME
    command += b"\0" * (size - len(command))
    out = bytearray(client)
    out[insert_at : insert_at + size] = command
    struct.pack_into("<II", out, 16, ncmds + 1, sizeofcmds + size)
    result = bytes(out)
    if LOAD_NAME.decode().strip("\0") not in load_names(result):
        raise RuntimeError("load command post-check failed")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("dylib", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if len({args.source.resolve(), args.dylib.resolve(), args.output.resolve()}) != 3:
        parser.error("source, dylib, and output paths must differ")
    source_bytes = args.source.read_bytes()
    dylib = args.dylib.read_bytes()
    if digest(source_bytes) != SOURCE_SHA256:
        parser.error("source IPA digest differs from the patched v146 Ultra build")
    if digest(dylib) != DYLIB_SHA256:
        parser.error("dylib digest differs from the last verified UI build")

    with zipfile.ZipFile(args.source, "r") as src, zipfile.ZipFile(args.output, "w") as dst:
        if DYLIB_MEMBER in src.namelist():
            raise ValueError("dylib already present in IPA")
        dst.comment = src.comment
        for info in src.infolist():
            data = src.read(info)
            if info.filename == CLIENT_MEMBER:
                data = patch_client(data)
            dst.writestr(info, data)
        info = zipfile.ZipInfo(DYLIB_MEMBER)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100755 << 16
        dst.writestr(info, dylib)

    with zipfile.ZipFile(args.output) as result:
        if result.testzip() is not None:
            raise RuntimeError("output ZIP integrity failed")
        if digest(result.read(DYLIB_MEMBER)) != DYLIB_SHA256:
            raise RuntimeError("embedded dylib digest mismatch")
        if LOAD_NAME.decode().strip("\0") not in load_names(result.read(CLIENT_MEMBER)):
            raise RuntimeError("embedded client load command missing")
    print(f"created {args.output}")
    print("rollback: use the patched IPA without the dylib")


if __name__ == "__main__":
    main()
