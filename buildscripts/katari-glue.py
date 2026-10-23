#!/usr/bin/env python3
"""Checks, or writes, the list of the JNI glue's signatures for MPVLib.GLUE_LEVEL.

A host compiles MPVLib in from the AAR and may load libplayer.so from elsewhere (Katari loads it
from the mpv add-on APK, which can be newer than the AAR). The two only work together if they
agree on the glue: the native methods MPVLib declares (`external` in Kotlin), which libplayer.so
implements, and the classes, methods and fields libplayer.so looks up in Java. Each glue level
has a list of those in libmpv/glue/level-<N>.txt, and MPVLib.GLUE_LEVEL names the current one.

The list is read from the AAR: the native methods (with their descriptors) of every class in
classes.jar, and the lookups from the JNI sources (FindClass, Get[Static]MethodID and
Get[Static]FieldID with literal arguments; anything else fails). With --readelf, each ABI's
libplayer.so must also export a function for every native method and nothing else, and contain
the names and descriptors it looks up.

  check  fails unless the list equals libmpv/glue/level-<GLUE_LEVEL>.txt, the newest level
  write  adds libmpv/glue/level-<GLUE_LEVEL>.txt after GLUE_LEVEL has been raised by one;
         it never rewrites the list of an existing level

Raise GLUE_LEVEL whenever a line of the list would change: a native method added, removed,
renamed, made static or given other parameter or return types, or a lookup added, removed or
changed (such as one of the static event methods libplayer.so calls). The check enforces that.
Raise it by hand, too, when the glue's behaviour changes in a way the list can't show, such as
what an argument means or on which thread a callback arrives; `write` then adds an identical
list. Changes that stay on one side don't count: Kotlin code a host compiles in (EndFile,
the observers, the constants) or native code behind the same signatures.

Usage: katari-glue.py check|write --aar <libmpv AAR> [--level <N>] [--readelf <llvm-readelf>]
  --level  fail unless the AAR's GLUE_LEVEL is <N> (katari-release.sh reads it from MPVLib.kt)
"""

import argparse
import difflib
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLUE_DIR = os.path.join(ROOT, "libmpv", "glue")
JNI_DIR = os.path.join(ROOT, "libmpv", "src", "main", "jni")
MPVLIB = "is/xyz/mpv/MPVLib"
ACC_STATIC, ACC_NATIVE = 0x0008, 0x0100

HEADER = """\
# libmpv glue level {level}
#
# The JNI contract between MPVLib, which a host compiles in from the AAR, and libplayer.so,
# which comes with the native libraries (in the AAR, or in the Katari mpv add-on). A host
# built with MPVLib.GLUE_LEVEL {level} can use the native libraries of any release whose glue
# level is {level}.
#
# Written by buildscripts/katari-glue.py from the AAR's classes.jar and libmpv/src/main/jni.
# Don't edit it: when the glue changes, raise MPVLib.GLUE_LEVEL and run katari-glue.py write.
"""
NATIVES = """
# Native methods, implemented by libplayer.so: [static-]native <class>.<name> <descriptor>
"""
LOOKUPS = """
# What libplayer.so looks up: class <class>, or [static-]method|field <class>.<name> <descriptor>
"""


def die(msg):
    print(f"katari-glue.py: {msg}", file=sys.stderr)
    sys.exit(1)


def read_class(data):
    """The class name, its native methods [(name, descriptor, static)], its int constants and
    its members {(kind, name, descriptor)}, kind as in the list (static-method, field, ...)."""
    pos = 0

    def take(fmt):
        nonlocal pos
        values = struct.unpack_from(">" + fmt, data, pos)
        pos += struct.calcsize(">" + fmt)
        return values if len(values) > 1 else values[0]

    if take("I") != 0xCAFEBABE:
        die("not a class file")
    take("HH")  # minor, major version
    pool, n = [None] * take("H"), 1
    while n < len(pool):
        tag = take("B")
        if tag == 1:
            length = take("H")
            # modified UTF-8: NUL is C0 80, and characters beyond the BMP are surrogate pairs
            utf = data[pos:pos + length].replace(b"\xc0\x80", b"\0")
            pool[n] = utf.decode("utf-8", "surrogatepass")
            pos += length
        elif tag == 3:
            pool[n] = take("i")
        elif tag in (5, 6):  # long and double take two entries
            pos, n = pos + 8, n + 1
        elif tag in (7, 8, 16, 19, 20):
            pool[n] = take("H")
        elif tag == 15:
            pos += 3
        elif tag in (4, 9, 10, 11, 12, 17, 18):
            pos += 4
        else:
            die(f"unknown constant pool tag {tag}")
        n += 1
    _, this, _, interfaces = take("HHHH")
    pos += 2 * interfaces

    def members():
        nonlocal pos
        for _ in range(take("H")):
            flags, name, desc, count = take("HHHH")
            attrs = {}
            for _ in range(count):
                attr, length = take("HI")
                attrs[pool[attr]] = data[pos:pos + length]
                pos += length
            yield flags, pool[name], pool[desc], attrs

    def kind(flags, what):
        return ("static-" if flags & ACC_STATIC else "") + what

    constants, declared = {}, set()
    for flags, name, desc, attrs in members():
        declared.add((kind(flags, "field"), name, desc))
        if desc == "I" and flags & ACC_STATIC and "ConstantValue" in attrs:
            constants[name] = pool[struct.unpack(">H", attrs["ConstantValue"])[0]]
    natives = []
    for flags, name, desc, _ in members():
        declared.add((kind(flags, "method"), name, desc))
        if flags & ACC_NATIVE:
            natives.append((name, desc, bool(flags & ACC_STATIC)))
    return pool[pool[this]], natives, constants, declared


def read_jar(aar):
    """The native methods [(class, name, descriptor, static)] in classes.jar, GLUE_LEVEL, and
    every class's members {class: {(kind, name, descriptor)}}."""
    with zipfile.ZipFile(aar) as z, zipfile.ZipFile(z.open("classes.jar")) as jar:
        natives, level, classes = [], None, {}
        for entry in jar.namelist():
            if entry.endswith(".class"):
                cls, methods, constants, classes[cls] = read_class(jar.read(entry))
                natives += [(cls, *m) for m in methods]
                if cls == MPVLIB:
                    level = constants.get("GLUE_LEVEL")
    if level is None:
        die(f"{aar}: classes.jar has no {MPVLIB}.GLUE_LEVEL")
    return natives, level, classes


def read_jni(jni_dir):
    """The classes [class] and the members [(kind, class, name, descriptor)] the JNI looks up."""
    classes, members, unread = {}, [], []
    for f in sorted(os.listdir(jni_dir)):
        if not f.endswith((".c", ".cpp", ".h")):
            continue
        text = open(os.path.join(jni_dir, f), encoding="utf-8").read()
        # comments and preprocessor lines aside, FIND_CLASS() is jni_utils.cpp's FindClass()
        text = re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"^\s*#[^\n]*", "", text, flags=re.M).replace("FIND_CLASS(", "FindClass(")
        for var, cls in re.findall(r"(\w+)\s*=[^;=]*?\bFindClass\(\s*\"([^\"]+)\"\s*\)", text):
            classes[var] = cls
        calls = re.findall(r"\b(?:FindClass|Get(?:Static)?(?:Method|Field)ID|GetObjectClass|"
                           r"GetSuperclass|RegisterNatives|FromReflected\w+)\s*"
                           r"\((?:\"[^\"]*\"|[^;\"])*", text)
        for call in calls:
            m = re.fullmatch(r"Get(Static)?(Method|Field)ID\(\s*(\w+)\s*,\s*\"([^\"]+)\"\s*,"
                             r"\s*\"([^\"]+)\"\s*\)", call.strip())
            if m:
                static, kind, var, name, desc = m.groups()
                if var not in classes:
                    unread.append(f"{f}: {call.strip()} (the class isn't a FindClass result)")
                kind = ("static-" if static else "") + kind.lower()
                members.append((kind, classes.get(var), name, desc))
            elif not re.fullmatch(r"FindClass\(\s*\"[^\"]+\"\s*\)\)?", call.strip()):
                unread.append(f"{f}: {call.strip()}")
    if unread:
        die("can't read these JNI lookups, so the glue can't be listed; use literal names, or "
            "teach katari-glue.py:\n  " + "\n  ".join(unread))
    return sorted(set(classes.values())), members


def entries(natives, classes, members):
    """The list's lines, without comments: natives first, then lookups, each sorted."""
    return ([f"{'static-' if s else ''}native {c}.{n} {d}" for c, n, d, s in sorted(natives)],
            [f"class {c}" for c in classes]
            + sorted(f"{k} {c}.{n} {d}" for k, c, n, d in set(members)))


def mangle(s):
    out = []
    for ch in s:
        if ch.isascii() and ch.isalnum():
            out.append(ch)
        else:
            out.append({"/": "_", "_": "_1", ";": "_2", "[": "_3"}.get(ch, f"_0{ord(ch):04x}"))
    return "".join(out)


def check_libs(aar, readelf, natives, members):
    """Each ABI's libplayer.so exports exactly the native methods and has the looked-up names."""
    problems = []
    with zipfile.ZipFile(aar) as z, tempfile.TemporaryDirectory() as tmp:
        libs = sorted(e for e in z.namelist() if re.fullmatch(r"jni/[^/]+/libplayer\.so", e))
        if not libs:
            die(f"{aar} has no jni/<abi>/libplayer.so")
        for lib in libs:
            path = os.path.join(tmp, "libplayer.so")
            with open(path, "wb") as f:
                f.write(z.read(lib))
            out = subprocess.run([readelf, "--dyn-syms", "--wide", path], check=True,
                                 capture_output=True, text=True).stdout
            exported = {cols[7] for cols in (line.split() for line in out.splitlines())
                        if len(cols) >= 8 and cols[6] != "UND" and cols[7].startswith("Java_")}
            for c, n, d, _ in natives:
                short = f"Java_{mangle(c)}_{mangle(n)}"
                long = f"{short}__{mangle(d[1:d.index(')')])}"
                if not exported & {short, long}:
                    problems.append(f"{lib} doesn't export {short}")
                exported -= {short, long}
            problems += [f"{lib} exports {s}, which no native method declares"
                         for s in sorted(exported)]
            data = z.read(lib)
            for _, c, n, d in members:
                for s in (c, n, d):
                    if s and s.encode() + b"\0" not in data:
                        problems.append(f"{lib} lacks {s!r}, which the JNI sources look up")
    if problems:
        die("the native libraries don't match the JNI sources and classes.jar:\n  "
            + "\n  ".join(sorted(set(problems))))


def read_list(path):
    return [line for line in open(path, encoding="utf-8").read().splitlines()
            if line and not line.startswith("#")]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["check", "write"])
    p.add_argument("--aar", required=True)
    p.add_argument("--level", type=int)
    p.add_argument("--readelf")
    args = p.parse_args()

    natives, level, jar = read_jar(args.aar)
    if args.level is not None and level != args.level:
        die(f"the AAR's GLUE_LEVEL is {level}, not {args.level} as in MPVLib.kt")
    if not natives:
        die(f"{args.aar}: classes.jar declares no native methods")
    classes, members = read_jni(JNI_DIR)
    # what libplayer.so looks up in the AAR's own classes must be there
    missing = [f"{k} {c}.{n} {d}" for k, c, n, d in members
               if c in jar and (k, n, d) not in jar[c]]
    missing += [f"class {c}" for c in classes if c.startswith("is/xyz/mpv/") and c not in jar]
    if missing:
        die("libmpv/src/main/jni looks up what classes.jar doesn't have:\n  "
            + "\n  ".join(missing))
    if args.readelf:
        check_libs(args.aar, args.readelf, natives, members)
    native_lines, lookup_lines = entries(natives, classes, members)
    lines = native_lines + lookup_lines

    levels = sorted(int(m.group(1)) for f in os.listdir(GLUE_DIR)
                    if (m := re.fullmatch(r"level-([1-9][0-9]*)\.txt", f))) \
        if os.path.isdir(GLUE_DIR) else []
    newest = levels[-1] if levels else 0
    path = os.path.join(GLUE_DIR, f"level-{level}.txt")
    rel = os.path.relpath(path, ROOT)
    write_cmd = ("buildscripts/katari-glue.py write --aar "
                 + os.path.relpath(os.path.abspath(args.aar), ROOT))

    if args.mode == "write":
        if level <= newest:
            die(f"{rel} already exists, and a level's list never changes. If the glue changed, "
                f"raise MPVLib.GLUE_LEVEL to {newest + 1}, rebuild the AAR and run this again")
        if level != newest + 1:
            die(f"GLUE_LEVEL is {level}, but the next level is {newest + 1}")
        os.makedirs(GLUE_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(HEADER.format(level=level) + NATIVES + "".join(f"{l}\n" for l in native_lines)
                    + LOOKUPS + "".join(f"{l}\n" for l in lookup_lines))
        print(f"Wrote {rel}")
        return

    if level < newest:
        die(f"GLUE_LEVEL is {level}, but {os.path.relpath(GLUE_DIR, ROOT)}/level-{newest}.txt "
            "exists; the level only goes up")
    if level > newest:
        die(f"GLUE_LEVEL is {level}, but there's no {rel}. If you raised it for a glue change, "
            f"run {write_cmd} (in the repository's root) to add it")
    have = read_list(path)
    if have != lines:
        diff = "\n".join(difflib.unified_diff(have, lines, rel, "the AAR's glue",
                                              lineterm="", n=0))
        die(f"the JNI glue changed, but MPVLib.GLUE_LEVEL is still {level}:\n{diff}\n\n"
            f"Hosts built with glue level {level} can't use these native libraries. Raise "
            f"MPVLib.GLUE_LEVEL to {level + 1} in libmpv/src/main/java/is/xyz/mpv/MPVLib.kt, "
            f"rebuild the AAR and run {write_cmd} (in the repository's root) to add "
            f"libmpv/glue/level-{level + 1}.txt. "
            f"Don't edit {rel}.")
    print(f"The JNI glue matches {rel} ({len(native_lines)} native methods, "
          f"{len(lookup_lines)} lookups)")


if __name__ == "__main__":
    main()
