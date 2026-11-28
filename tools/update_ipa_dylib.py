"""Replace an already loaded UI dylib without modifying the client executable."""
import argparse
import hashlib
import shutil
import struct
import zipfile
from pathlib import Path

from inject_v146_dylib import CLIENT_MEMBER, DYLIB_MEMBER, LOAD_NAME, load_names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('dylib', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if len({p.resolve() for p in (args.source, args.dylib, args.output)}) != 3:
        parser.error('source, dylib, and output must differ')
    if args.output.exists():
        parser.error('output already exists')
    data = args.dylib.read_bytes()
    if len(data) < 32 or struct.unpack_from('<II', data) != (0xFEEDFACF, 0x0100000C):
        parser.error('replacement must be a thin ARM64 Mach-O')
    if struct.unpack_from('<I', data, 12)[0] != 6:
        parser.error('replacement is not a Mach-O dylib')
    load_names(data)  # Validate load-command boundaries.
    partial = args.output.with_suffix('.ipa.partial')
    if partial.exists():
        parser.error('partial output already exists')
    try:
        with zipfile.ZipFile(args.source) as src:
            names = src.namelist()
            if len(names) != len(set(names)) or names.count(DYLIB_MEMBER) != 1:
                raise ValueError('source must have unique entries and one existing UI dylib')
            if LOAD_NAME.decode().rstrip('\0') not in load_names(src.read(CLIENT_MEMBER)):
                raise ValueError('client does not already load this dylib')
            with zipfile.ZipFile(partial, 'x', allowZip64=True) as dst:
                dst.comment = src.comment
                for info in src.infolist():
                    if info.filename == DYLIB_MEMBER:
                        dst.writestr(info, data)
                    else:
                        with src.open(info) as reader, dst.open(info, 'w') as writer:
                            shutil.copyfileobj(reader, writer, 1024 * 1024)
            with zipfile.ZipFile(partial) as result:
                if result.testzip() is not None:
                    raise ValueError('ZIP integrity check failed')
                if result.read(DYLIB_MEMBER) != data:
                    raise ValueError('replacement bytes differ')
                for info in src.infolist():
                    actual = result.getinfo(info.filename)
                    if info.filename != DYLIB_MEMBER and (actual.CRC, actual.file_size) != (info.CRC, info.file_size):
                        raise ValueError('unexpected changed entry: ' + info.filename)
        partial.rename(args.output)
    except Exception:
        if partial.exists():
            partial.unlink()
        raise
    print('Created:', args.output)
    print('Dylib SHA256:', hashlib.sha256(data).hexdigest())
    print('All other entries verified unchanged; IPA requires signing before installation.')


if __name__ == '__main__':
    main()
