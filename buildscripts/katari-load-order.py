#!/usr/bin/env python3
"""Prints, as JSON, the order in which a host must load the native libraries, per ABI.

MPVLib doesn't load its libraries, and a host that loads them by absolute path (for example
from another APK) gets no help from the linker: it resolves each DT_NEEDED entry only against
libraries already loaded. So the libraries are listed dependencies first, computed from their
DT_NEEDED entries: by depth (the longest chain of bundled libraries a library depends on), then
by name, so the output is stable.

Fails if a library's soname isn't its file name, if the libraries depend on each other in a
cycle, or if one needs a library that isn't bundled and isn't one of the NDK's system
libraries for the given API level.

Usage: katari-load-order.py --readelf <llvm-readelf> --sysroot <NDK sysroot> --api <level>
           --version <version> --abi <abi> [--abi <abi>]... <dir with an <abi>/ per ABI>
"""

import argparse
import json
import os
import re
import subprocess
import sys

TRIPLES = {
    "armeabi-v7a": "arm-linux-androideabi",
    "arm64-v8a": "aarch64-linux-android",
    "x86": "i686-linux-android",
    "x86_64": "x86_64-linux-android",
}


def die(msg):
    print(f"katari-load-order.py: {msg}", file=sys.stderr)
    sys.exit(1)


def dynamic(readelf, path):
    """The soname and the DT_NEEDED entries of an ELF file."""
    out = subprocess.run([readelf, "--dynamic-table", path], check=True,
                         capture_output=True, text=True).stdout
    soname, needed = None, []
    for tag, value in re.findall(r"\((NEEDED|SONAME)\)\s.*\[(.+)\]", out):
        if tag == "SONAME":
            soname = value
        else:
            needed.append(value)
    return soname, needed


def load_order(args, abi):
    libdir = os.path.join(args.dir, abi)
    if not os.path.isdir(libdir):
        die(f"{libdir} doesn't exist")
    sysdir = os.path.join(args.sysroot, "usr", "lib", TRIPLES[abi], str(args.api))
    system = {f for f in os.listdir(sysdir) if f.endswith(".so")}

    needs = {}
    for lib in sorted(f for f in os.listdir(libdir) if f.endswith(".so")):
        soname, needed = dynamic(args.readelf, os.path.join(libdir, lib))
        # the linker matches DT_NEEDED entries against sonames
        if soname != lib:
            die(f"{abi}/{lib} has the soname {soname}")
        needs[lib] = needed
    if not needs:
        die(f"{libdir} has no libraries")

    missing = sorted({f"{lib} needs {n}" for lib, needed in needs.items() for n in needed
                      if n not in needs and n not in system})
    if missing:
        die(f"{abi}: not bundled and not an Android {args.api} system library: "
            + ", ".join(missing))

    # each library's depth is the length of its longest chain of bundled dependencies
    bundled = {lib: {n for n in needed if n in needs} for lib, needed in needs.items()}
    depth = {}
    while len(depth) < len(bundled):
        ready = {lib: 1 + max((depth[d] for d in deps), default=-1)
                 for lib, deps in bundled.items() if lib not in depth and deps <= depth.keys()}
        if not ready:
            die(f"{abi}: dependency cycle among "
                + ", ".join(sorted(bundled.keys() - depth.keys())))
        depth.update(ready)
    return sorted(bundled, key=lambda lib: (depth[lib], lib))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--readelf", required=True)
    p.add_argument("--sysroot", required=True)
    p.add_argument("--api", type=int, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--abi", action="append", required=True, choices=sorted(TRIPLES))
    p.add_argument("dir")
    args = p.parse_args()

    json.dump({
        "format": 1,
        "name": f"libmpv-android-{args.version}",
        "version": args.version,
        "loadOrder": {abi: load_order(args, abi) for abi in sorted(args.abi)},
    }, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
