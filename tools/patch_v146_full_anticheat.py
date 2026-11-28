"""Full anti-cheat patcher and injector for ROS Hariki iOS v146 Ultra IPA.

Patches:
1. Payload/client.app/Frameworks/HK.framework/HK:
   - 0x4014: NOP dyld callback registration (__dyld_register_func_for_add_image)
   - 0x537C: RET HK report/auto-ban sender
2. Payload/client.app/client:
   - 0x104af90: is_outlaw_device -> force Py_False (neutralize jailbreak detection)
   - 0x104d664: inspect_loaded_modules -> NOP blr x8 (skip dylib scan, return Py_None)
   - 0x104d4e0: mobile_acsdk_check -> zero SSO std::string buffer, skip blr x9 (return clean "")
   - 0x104cddc: anti_cheat_check -> zero 8-byte output buffer, skip blr x8 (return clean 8-byte null token)
   - 0x104d710: check_graphic_states -> force Py_False (neutralize overlay / graphics state detection)
   - 0x104d740: inspect_system_processes -> NOP blr x8 (skip process inspection)
   - 0x104d778: inspect_system_windows -> NOP blr x8 (skip window / UI overlay inspection)
3. Optional: Inject RosModV2UI.dylib via LC_LOAD_DYLIB in client.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import zipfile
from pathlib import Path

SOURCE_SHA256 = "b74cdfb5a238bcee0eb6b6cf3e6fe263cf2c8d6bbb20f37b1490bf3b1bdaffe2"
HK_SHA256 = "2b4b5a6facc4196352f1ef9dde1fe89622bbf2df864be72472257eda639bbb31"
CLIENT_SHA256 = "27ebb92b0d774bef1d56c21fccf339a58be101ca835c7eb710b4ef94b5c47fce"

HK_MEMBER = "Payload/client.app/Frameworks/HK.framework/HK"
CLIENT_MEMBER = "Payload/client.app/client"
DYLIB_MEMBER = "Payload/client.app/Frameworks/RosModV2UI.dylib"
LOAD_NAME = b"@executable_path/Frameworks/RosModV2UI.dylib\0"
LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C

NOP = bytes.fromhex("1f2003d5")
RET = bytes.fromhex("c0035fd6")

HK_PATCHES = (
    # __dyld_register_func_for_add_image callback registration
    (0x4014, bytes.fromhex("a0c80194"), NOP),
    # HK report sender called from detection branches
    (0x537C, bytes.fromhex("fc6fbaa9"), RET),
)

CLIENT_PATCHES = (
    # is_outlaw_device: csel x0, x9, x8, ne -> mov x0, x8 (always select Py_False)
    (0x104AF90, bytes.fromhex("2011889a"), bytes.fromhex("e00308aa")),
    # inspect_loaded_modules: blr x8 -> nop (skip dylib inspection, cleanly return Py_None)
    (0x104D664, bytes.fromhex("00013fd6"), NOP),
    # mobile_acsdk_check: add x8, sp, #8; blr x9 -> str xzr, [sp, #8]; strb wzr, [sp, #0x1f]
    (0x104D4E0, bytes.fromhex("e823009120013fd6"), bytes.fromhex("ff0700f9ff7f0039")),
    # anti_cheat_check: blr x8 -> stur xzr, [x29, #-0x10] (zero 8-byte buffer, clean PyString return)
    (0x104CDDC, bytes.fromhex("00013fd6"), bytes.fromhex("bf031ff8")),
    # check_graphic_states: csel x0, x9, x8, ne -> mov x0, x8 (always select Py_False, hide overlay)
    (0x104D710, bytes.fromhex("2011889a"), bytes.fromhex("e00308aa")),
    # inspect_system_processes: blr x8 -> nop (skip process scan)
    (0x104D740, bytes.fromhex("00013fd6"), NOP),
    # inspect_system_windows: blr x8 -> nop (skip window / UI overlay scan)
    (0x104D778, bytes.fromhex("00013fd6"), NOP),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def apply_patches(data: bytes, patches: tuple[tuple[int, bytes, bytes], ...], name: str) -> bytes:
    out = bytearray(data)
    for offset, original, replacement in patches:
        actual = bytes(out[offset : offset + len(original)])
        if actual != original:
            raise ValueError(f"{name} bytes at 0x{offset:x}: expected {original.hex()}, got {actual.hex()}")
        out[offset : offset + len(original)] = replacement
    return bytes(out)


def patch_hk(data: bytes) -> bytes:
    if sha256(data) != HK_SHA256:
        raise ValueError("HK binary SHA-256 differs from the measured v146 Ultra build")
    return apply_patches(data, HK_PATCHES, "HK")


def inject_load_dylib(client: bytearray) -> None:
    if struct.unpack_from("<I", client, 0)[0] != MH_MAGIC_64 or struct.unpack_from("<I", client, 4)[0] != CPU_TYPE_ARM64:
        raise ValueError("client is not arm64 Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", client, 16)
    insert_at = 32 + sizeofcmds
    size = (24 + len(LOAD_NAME) + 7) & ~7
    if insert_at + size > 0x4000 or any(client[insert_at : insert_at + size]):
        raise ValueError("no verified zero padding for new load command")
    command = struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 0, 0, 0) + LOAD_NAME
    command += b"\0" * (size - len(command))
    client[insert_at : insert_at + size] = command
    struct.pack_into("<II", client, 16, ncmds + 1, sizeofcmds + size)


def patch_client(data: bytes, dylib: bytes | None = None) -> bytes:
    if sha256(data) != CLIENT_SHA256:
        raise ValueError("client binary SHA-256 differs from the measured v146 Ultra build")
    out = bytearray(apply_patches(data, CLIENT_PATCHES, "client"))
    if dylib is not None:
        inject_load_dylib(out)
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Path to ROS-Hariki-iOS-v146-Ultra-8GB-unsigned.ipa")
    parser.add_argument("output", type=Path, help="Path to destination patched IPA")
    parser.add_argument("--dylib", type=Path, default=None, help="Optional RosModV2UI.dylib to embed")
    args = parser.parse_args()

    if args.source.resolve() == args.output.resolve():
        parser.error("output must differ from source")

    source_data = args.source.read_bytes()
    if sha256(source_data) != SOURCE_SHA256:
        parser.error("source IPA SHA-256 differs from the measured v146 Ultra build")

    dylib_data = args.dylib.read_bytes() if args.dylib else None

    with zipfile.ZipFile(args.source, "r") as src, zipfile.ZipFile(args.output, "w") as dst:
        if HK_MEMBER not in src.namelist():
            raise ValueError(f"missing {HK_MEMBER}")
        if CLIENT_MEMBER not in src.namelist():
            raise ValueError(f"missing {CLIENT_MEMBER}")

        dst.comment = src.comment
        for info in src.infolist():
            data = src.read(info)
            if info.filename == HK_MEMBER:
                data = patch_hk(data)
            elif info.filename == CLIENT_MEMBER:
                data = patch_client(data, dylib_data)
            dst.writestr(info, data)

        if dylib_data is not None:
            info = zipfile.ZipInfo(DYLIB_MEMBER)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100755 << 16
            dst.writestr(info, dylib_data)

    # Post-check verification
    with zipfile.ZipFile(args.output, "r") as result:
        if result.testzip() is not None:
            raise RuntimeError("output ZIP integrity failed")

        hk = result.read(HK_MEMBER)
        for offset, _original, replacement in HK_PATCHES:
            if hk[offset : offset + len(replacement)] != replacement:
                raise RuntimeError(f"post-check failed at HK 0x{offset:x}")

        client = result.read(CLIENT_MEMBER)
        for offset, _original, replacement in CLIENT_PATCHES:
            if client[offset : offset + len(replacement)] != replacement:
                raise RuntimeError(f"post-check failed at client 0x{offset:x}")

        if dylib_data is not None:
            if result.read(DYLIB_MEMBER) != dylib_data:
                raise RuntimeError("dylib member verification failed")

    print(f"successfully built {args.output}")
    print(f"patched HK SHA-256: {sha256(hk)}")
    print(f"patched client SHA-256: {sha256(client)}")
    print(f"output IPA SHA-256: {sha256(args.output.read_bytes())}")


if __name__ == "__main__":
    main()
