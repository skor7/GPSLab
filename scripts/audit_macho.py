#!/usr/bin/env python3
"""Deterministic, read-only Mach-O release audit for GPSLab.

Prints one stable ``key: value`` line per metric so the output can be diffed
between a "before" and an "after" build. It never prints string *contents* that
could be sensitive: findings are reported as ``pattern -> count`` only.

Usage:
    python3 scripts/audit_macho.py <path-to-dylib> [--json] [--symbols]

`--symbols` additionally lists the names of defined symbols. Names are not
secret, but the default output omits them so a normal audit never surfaces any
embedded string content.

Exit code 0 always (this is a measurement tool). Hardening assertions live in
scripts/release_protection.sh, which consumes this output.
"""

import argparse
import hashlib
import json
import re
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_ID_DYLIB = 0x0D
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18
LC_REEXPORT_DYLIB = 0x1F
LC_LOAD_UPWARD_DYLIB = 0x23
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_CODE_SIGNATURE = 0x1D
PLATFORM_IOS = 2
DYLIB_COMMANDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}
HEADER_SIZE = 32
NLIST64_SIZE = 16
MIN_STRING = 6

# nlist_64 n_type masks.
N_STAB = 0xE0
N_TYPE = 0x0E
N_EXT = 0x01
N_UNDF = 0x00
N_SECT = 0x0E

# STABS that carry compiler/build metadata rather than source debug info.
# N_OPT (0x3C) is the standard "radr://..." debug-map placeholder that `strip`
# and the Darwin linker leave behind in an otherwise stripped binary.
NON_SOURCE_STAB = {0x3C, 0x88, 0x8A}  # N_OPT, N_VERSION, N_OLEVEL

# Leak patterns must be ZERO in a release binary; they are reported by name +
# count only (never the matched bytes). A hit is a release-protection failure.
LEAK_PATTERNS = [
    ("build_path_absolute", re.compile(rb"/(?:Users|home)/[^\x00]{0,96}")),
    ("windows_path_absolute", re.compile(rb"[A-Za-z]:\\[^\x00]{0,96}")),
    ("source_file_debug", re.compile(rb"Source/[A-Za-z0-9_]+\.(?:m|c|h)")),
    ("banned_hooking", re.compile(rb"(?i)substrate|ellekit|libhooker|cydia")),
    ("private_key_marker", re.compile(rb"BEGIN [A-Z ]*PRIVATE KEY")),
]

# Informational patterns are expected in some builds (e.g. the Security
# framework constant kSecClassGenericPassword contains "Password"); they are
# reported for review but never fail the audit.
NOTE_PATTERNS = [
    ("credential_literal", re.compile(rb"(?i)(?:password|passwd|api[_-]?key|bearer )")),
]


def decode_version(value):
    return f"{(value >> 16) & 0xFFFF}.{(value >> 8) & 0xFF}.{value & 0xFF}"


def parse_thin(data):
    if len(data) < HEADER_SIZE:
        raise ValueError("file is smaller than a Mach-O header")
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise ValueError(f"not a 64-bit little-endian Mach-O (magic={magic:#x})")
    cputype = struct.unpack_from("<I", data, 4)[0]
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    if HEADER_SIZE + sizeofcmds > len(data):
        raise ValueError("load commands extend past the end of the file")

    install_name = None
    dependencies = []
    min_os = None
    sections = []
    dwarf_present = False
    code_signature = False
    symtab = None
    offset = HEADER_SIZE
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        base = cmd & ~LC_REQ_DYLD
        if base == LC_CODE_SIGNATURE:
            code_signature = True
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
        elif base == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, offset + 8)
            symtab = (symoff, nsyms, stroff, strsize)
        elif base == LC_SEGMENT_64:
            segname = data[offset + 8:offset + 24].split(b"\0", 1)[0].decode("ascii", "replace")
            if segname == "__DWARF":
                dwarf_present = True
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            sec_off = offset + 72
            for _ in range(nsects):
                sectname = data[sec_off:sec_off + 16].split(b"\0", 1)[0].decode("ascii", "replace")
                sections.append(sectname)
                sec_off += 80
        offset += cmdsize

    symbol_counts = {
        "total": 0,
        "local": 0,
        "external_defined": 0,
        "undefined": 0,
        "stab": 0,
        "stab_source": 0,
        "stab_metadata": 0,
    }
    defined_symbol_names = []
    if symtab is not None:
        symoff, nsyms, stroff, strsize = symtab
        string_end = stroff + strsize
        for i in range(nsyms):
            pos = symoff + i * NLIST64_SIZE
            if pos + NLIST64_SIZE > len(data):
                break
            n_strx = struct.unpack_from("<I", data, pos)[0]
            n_type = data[pos + 4]
            symbol_counts["total"] += 1
            if n_type & N_STAB:
                symbol_counts["stab"] += 1
                if n_type in NON_SOURCE_STAB:
                    symbol_counts["stab_metadata"] += 1
                else:
                    symbol_counts["stab_source"] += 1
                continue
            kind = n_type & N_TYPE
            if kind == N_UNDF:
                symbol_counts["undefined"] += 1
            elif kind == N_SECT:
                if n_type & N_EXT:
                    symbol_counts["external_defined"] += 1
                else:
                    symbol_counts["local"] += 1
                # Symbol NAMES are only surfaced when the caller opts in with
                # --symbols (the KeychainFix gate needs them); the default output
                # stays name-free so it never leaks embedded string contents.
                if stroff <= string_end <= len(data):
                    name_end = data.find(b"\0", stroff + n_strx, string_end)
                    if name_end > 0:
                        defined_symbol_names.append(
                            data[stroff + n_strx:name_end].decode("utf-8", "replace")
                        )

    return {
        "arch": "arm64" if cputype == CPU_TYPE_ARM64 else f"cputype={cputype:#x}",
        "install_name": install_name,
        "min_os": decode_version(min_os) if min_os is not None else "unknown",
        "dependencies": dependencies,
        "sections": sections,
        "dwarf_debug_segment": dwarf_present,
        "code_signature": code_signature,
        "symbols": symbol_counts,
        "defined_symbol_names": defined_symbol_names,
        "size_bytes": len(data),
    }


def extract_strings(data):
    runs = re.findall(rb"[\x20-\x7e]{%d,}" % MIN_STRING, data)
    return runs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--symbols",
        action="store_true",
        help="also print the names of defined symbols (opt-in; names are not secrets)",
    )
    args = parser.parse_args()

    with open(args.path, "rb") as handle:
        data = handle.read()

    digest = hashlib.sha256(data).hexdigest()
    if len(data) >= 4 and struct.unpack_from(">I", data, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64):
        raise SystemExit("fat Mach-O is not supported by this audit; pass a thin arm64 slice")

    info = parse_thin(data)
    strings = extract_strings(data)
    leaks = {}
    for name, pattern in LEAK_PATTERNS:
        count = sum(1 for s in strings if pattern.search(s))
        if count:
            leaks[name] = count
    notes = {}
    for name, pattern in NOTE_PATTERNS:
        count = sum(1 for s in strings if pattern.search(s))
        if count:
            notes[name] = count

    info["sha256"] = digest
    info["string_count"] = len(strings)
    info["leaks"] = leaks
    info["notes"] = notes

    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True))
        return

    print(f"path: {args.path}")
    print(f"size_bytes: {info['size_bytes']}")
    print(f"sha256: {digest}")
    print(f"arch: {info['arch']}")
    print(f"install_name: {info['install_name']}")
    print(f"min_os: {info['min_os']}")
    print(f"dependencies: {len(info['dependencies'])}")
    for dep in info["dependencies"]:
        print(f"  dep: {dep}")
    print(f"sections: {len(info['sections'])}")
    for section in info["sections"]:
        print(f"  section: {section}")
    print(f"dwarf_debug_segment: {str(info['dwarf_debug_segment']).lower()}")
    print(f"code_signature: {str(info['code_signature']).lower()}")
    print(f"symbols_total: {info['symbols']['total']}")
    print(f"symbols_local: {info['symbols']['local']}")
    print(f"symbols_external_defined: {info['symbols']['external_defined']}")
    print(f"symbols_undefined: {info['symbols']['undefined']}")
    print(f"symbols_stab: {info['symbols']['stab']}")
    print(f"symbols_stab_source: {info['symbols']['stab_source']}")
    print(f"symbols_stab_metadata: {info['symbols']['stab_metadata']}")
    print(f"string_count: {info['string_count']}")
    if args.symbols:
        for name in sorted(set(info["defined_symbol_names"])):
            print(f"symbol: {name}")
    if leaks:
        for name in sorted(leaks):
            print(f"leak[{name}]: {leaks[name]}")
    else:
        print("leak: none")
    for name in sorted(notes):
        print(f"note[{name}]: {notes[name]}")


if __name__ == "__main__":
    main()
