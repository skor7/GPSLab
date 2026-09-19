#!/usr/bin/env python3
"""Print the GPSLab dylib contract: arch, install_name, min OS, dependencies.

Local helper mirroring the CI Mach-O assertions; it only reads the binary.
Usage: python3 scripts/inspect_dylib.py <path-to-dylib>
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_REQ_DYLD = 0x80000000
LC_ID_DYLIB = 0x0D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
DYLIB_COMMANDS = {0x0C, 0x18, 0x1F, 0x23}
HEADER_SIZE = 32
MIN_COMMAND_SIZE = 8


def decode_version(value):
    return f"{(value >> 16) & 0xFFFF}.{(value >> 8) & 0xFF}.{value & 0xFF}"


def main(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < HEADER_SIZE or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        sys.exit("not a 64-bit little-endian Mach-O")
    cputype = struct.unpack_from("<I", data, 4)[0]
    if cputype != CPU_TYPE_ARM64:
        sys.exit(f"not arm64 (cputype={cputype:#x})")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = HEADER_SIZE
    install_name = None
    dependencies = []
    min_os = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base = cmd & ~LC_REQ_DYLD
        if base in DYLIB_COMMANDS or base == LC_ID_DYLIB:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            start = offset + name_offset
            end = data.find(b"\0", start, offset + cmdsize)
            name = data[start:end].decode("utf-8", "replace")
            if base == LC_ID_DYLIB:
                install_name = name
            else:
                dependencies.append(name)
        elif base == LC_BUILD_VERSION:
            platform, minos = struct.unpack_from("<II", data, offset + 8)
            if platform == PLATFORM_IOS:
                min_os = minos
        elif base == LC_VERSION_MIN_IPHONEOS:
            min_os = struct.unpack_from("<I", data, offset + 8)[0]
        offset += cmdsize

    print("arch: arm64")
    print("install_name:", install_name)
    print("min_os:", decode_version(min_os) if min_os is not None else "unknown")
    print("dependencies:", dependencies)
    print("size_bytes:", len(data))


if __name__ == "__main__":
    main(sys.argv[1])
