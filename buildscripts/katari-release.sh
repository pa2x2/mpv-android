#!/bin/bash -e

# Builds a Katari libmpv release into buildscripts/release/:
# - libmpv-android-<version>.aar: libmpv, FFmpeg and the JNI glue (MPVLib) for each ABI,
#   with the licence notices as assets/libmpv/
# - ...-sources.tar: the LGPL corresponding source, i.e. the exact upstream archives the
#   build used plus this repository's build scripts
# - ...-THIRD_PARTY_LICENSES.txt, ...-third-party.json: the licence inventory and texts
# - ...-licence-evidence.txt: the licence settings read back from the build
# - ...-SHA256SUMS.txt
# .github/workflows/katari-release.yml only runs this script. Needs bash 4 and python3.
#
# Usage: ./katari-release.sh [--arch <arch>]... [--build <n>] [--expect-version <version>]
#   --arch            armv7l, arm64 or x86_64, repeatable (default: all three)
#   --build           build number, the last part of the version (default: 1)
#   --expect-version  fail unless the computed version is this one (the workflow passes the tag's)

cd "$( dirname "${BASH_SOURCE[0]}" )"
. ./include/depinfo.sh

archs=()
build=1
expect=
while [ $# -gt 0 ]; do
	case "$1" in
		--arch) shift; archs+=("$1") ;;
		--build) shift; build=$1 ;;
		--expect-version) shift; expect=$1 ;;
		*) echo "Unknown argument $1" >&2; exit 1 ;;
	esac
	shift
done
[ ${#archs[@]} -eq 0 ] && archs=(armv7l arm64 x86_64)

# <mpv release>.<mpv commit date>-ff<FFmpeg release>-<build>; <build> counts releases of the same upstream versions
version=$v_mpv_base.$v_mpv_date-ff$v_ffmpeg-$build
name=libmpv-android-$version
repo_url=${KATARI_REPO_URL:-https://github.com/pa2x2/mpv-android}
out=$PWD/release
notices=$PWD/../libmpv/build/generated/notices/libmpv
aar=../libmpv/build/outputs/aar/libmpv-release.aar
ffmpeg_libs=(avcodec avfilter avformat avutil swresample swscale)

msg () { printf '\e[1;34m==> %s\e[m\n' "$1"; }
die () { printf '\e[1;31m%s\e[m\n' "$1" >&2; exit 1; }

abi () {
	case "$1" in
		armv7l) echo armeabi-v7a ;;
		arm64) echo arm64-v8a ;;
		x86_64) echo x86_64 ;;
		*) die "Unsupported arch $1" ;;
	esac
}

if [[ -n "$expect" && "$expect" != "$version" ]]; then
	die "This tree builds version $version, not $expect"
fi
for arch in "${archs[@]}"; do abi "$arch" >/dev/null; done
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	die "The working tree has uncommitted changes, so the source bundle wouldn't match the build"
fi

msg "Building $name for ${archs[*]}"
rm -rf "$out" "$notices"
mkdir -p "$out" "$notices"

msg "Fetching the SDK, NDK and sources"
./download.sh

for arch in "${archs[@]}"; do
	msg "Building the native libraries ($arch)"
	./buildall.sh --arch "$arch" mpv
done

# Fail unless FFmpeg and mpv were configured and built as LGPL, and record the evidence.
check_lgpl () {
	local arch=$1 ffbuild=deps/ffmpeg/_build_$1 mpvbuild=deps/mpv/_build_$1 lib=prefix/$1/lib
	local line l
	for line in '#define CONFIG_GPL 0' '#define CONFIG_NONFREE 0' '#define CONFIG_VERSION3 1' \
			'#define FFMPEG_LICENSE "LGPL version 3 or later"'; do
		grep -qxF "$line" "$ffbuild/config.h" || die "FFmpeg ($arch): config.h lacks: $line"
	done
	grep -qx '!CONFIG_GPL=yes' "$ffbuild/ffbuild/config.mak" || die "FFmpeg ($arch): GPL is enabled in config.mak"
	grep -qxF '#define HAVE_GPL 0' "$mpvbuild/config.h" || die "mpv ($arch): built with gpl=true"
	for l in "${ffmpeg_libs[@]}"; do
		grep -qaF "lib$l license: LGPL version 3 or later" "$lib/lib$l.so" || die "lib$l.so ($arch) is not LGPL"
	done
	grep -qaF -- '-Dgpl=false' "$lib/libmpv.so" || die "libmpv.so ($arch) was not configured with -Dgpl=false"
	[ ! -e "$lib/libpostproc.so" ] || die "libpostproc.so ($arch) is GPL-only"

	echo "== $arch ($(abi "$arch"))"
	echo "-- FFmpeg $ffbuild/config.h"
	grep -E '^#define (CONFIG_GPL|CONFIG_GPLV3|CONFIG_NONFREE|CONFIG_VERSION3|FFMPEG_LICENSE) ' "$ffbuild/config.h"
	echo "-- FFmpeg $ffbuild/ffbuild/config.mak"
	grep -E '^!?CONFIG_(GPL|GPLV3|NONFREE|VERSION3)=' "$ffbuild/ffbuild/config.mak"
	echo "-- FFmpeg configure line (FFMPEG_CONFIGURATION)"
	grep -E '^#define FFMPEG_CONFIGURATION ' "$ffbuild/config.h" | sed "s|$PWD/||g"
	echo "-- strings in the FFmpeg libraries (avXXX_license())"
	for l in "${ffmpeg_libs[@]}"; do
		echo "lib$l.so: $(grep -aoF "lib$l license: LGPL version 3 or later" "$lib/lib$l.so")"
	done
	echo "-- mpv $mpvbuild/config.h"
	grep -E '^#define HAVE_(GPL|LUA|LIBCURL|LIBAVDEVICE|JAVASCRIPT) ' "$mpvbuild/config.h"
	echo "-- string in libmpv.so (mpv-configuration)"
	grep -ao -- '-Ddefault_library=[[:print:]]*' "$lib/libmpv.so" | head -n1 | sed "s|$PWD/||g"
	echo
}

msg "Checking the licences"
evidence=$out/$name-licence-evidence.txt
{
	echo "Licence evidence for $name, read back from the build"
	echo
	for arch in "${archs[@]}"; do check_lgpl "$arch"; done
} >"$evidence"

msg "Writing the licence notices"
ndk=sdk/android-ndk-$v_ndk
# libc++'s section of the toolchain NOTICE
awk '/^The LLVM Project is under the Apache License/ { n++ } { b[n] = b[n] $0 "\n" }
	END { for (i in b) if (b[i] ~ /The libc\+\+ library is dual licensed/) { printf "%s", b[i]; exit } }' \
	"$ndk/toolchains/llvm/prebuilt/"*/NOTICE >"$notices/.libcxx-LICENSE.txt"
[ -s "$notices/.libcxx-LICENSE.txt" ] || die "libc++ licence not found in the NDK NOTICE"
submodule () { git -C deps/libplacebo rev-parse "HEAD:3rdparty/$1" | cut -c1-9; }
# name | version | licence (SPDX) | homepage | where it is | licence files
cat >"$notices/.components" <<EOF
mpv|$v_mpv_base (git ${v_mpv:0:9}, $v_mpv_date)|LGPL-2.1-or-later|https://mpv.io/|libmpv.so|deps/mpv/LICENSE.LGPL
FFmpeg|$v_ffmpeg|LGPL-3.0-or-later|https://ffmpeg.org/|$(printf 'lib%s.so, ' "${ffmpeg_libs[@]}" | sed 's/, $//')|deps/ffmpeg/COPYING.LGPLv3 deps/ffmpeg/COPYING.GPLv3
dav1d|$v_dav1d|BSD-2-Clause|https://code.videolan.org/videolan/dav1d|libavcodec.so (static)|deps/dav1d/COPYING
Mbed TLS|$v_mbedtls|Apache-2.0|https://github.com/Mbed-TLS/mbedtls|libavformat.so (static)|deps/mbedtls/LICENSE
libxml2|$v_libxml2|MIT|https://gitlab.gnome.org/GNOME/libxml2|libavformat.so, libmpv.so (static)|deps/libxml2/Copyright
libplacebo|$v_libplacebo|LGPL-2.1-or-later|https://code.videolan.org/videolan/libplacebo|libmpv.so (static)|deps/libplacebo/LICENSE
fast_float|git $(submodule fast_float) (in libplacebo)|MIT OR Apache-2.0 OR BSL-1.0|https://github.com/fastfloat/fast_float|libmpv.so (static)|deps/libplacebo/3rdparty/fast_float/LICENSE-MIT
glad|git $(submodule glad) (OpenGL loader generated into libplacebo)|MIT AND Apache-2.0|https://github.com/Dav1dde/glad|libmpv.so (static)|deps/libplacebo/3rdparty/glad/LICENSE
libass|$v_libass|ISC|https://github.com/libass/libass|libmpv.so (static)|deps/libass/COPYING
FreeType|$v_freetype|FTL|https://freetype.org/|libmpv.so (static)|deps/freetype2/docs/FTL.TXT
HarfBuzz|$v_harfbuzz|MIT-Modern-Variant|https://harfbuzz.github.io/|libmpv.so (static)|deps/harfbuzz/COPYING
FriBidi|$v_fribidi|LGPL-2.1-or-later|https://github.com/fribidi/fribidi|libmpv.so (static)|deps/fribidi/COPYING
libunibreak|$v_unibreak|Zlib|https://github.com/adah1972/libunibreak|libmpv.so (static)|deps/unibreak/LICENCE
Fontconfig|$v_fontconfig|HPND-sell-variant|https://www.freedesktop.org/wiki/Software/fontconfig/|libmpv.so (static)|deps/fontconfig/COPYING
mpv-android (MPVLib and its JNI side)|git $(git rev-parse --short=9 HEAD)|MIT|$repo_url|libplayer.so, classes.jar|../LICENSE
LLVM libc++ (Android NDK $v_ndk)|$v_ndk_n|Apache-2.0 WITH LLVM-exception|https://github.com/llvm/llvm-project|libc++_shared.so|$notices/.libcxx-LICENSE.txt
EOF
python3 - "$name" "$repo_url/releases/tag/libmpv-$version" "$notices" <<'PY'
import hashlib, json, sys
name, release, notices = sys.argv[1:]
components = [line.rstrip("\n").split("|") for line in open(f"{notices}/.components")]
inventory, texts, seen = [], [], {}
for comp, version, spdx, url, where, files in components:
    entry = {"name": comp, "version": version, "license": spdx, "url": url, "binaries": where, "licenseTexts": []}
    for path in files.split():
        text = open(path, encoding="utf-8", errors="replace").read()
        # the same licence text, reflowed, is printed once
        digest = hashlib.sha256(" ".join(text.split()).encode()).hexdigest()
        label = f"{comp}: {path.split('/')[-1].lstrip('.')}"
        entry["licenseTexts"].append(seen.setdefault(digest, label))
        if seen[digest] == label:
            texts.append(f"---- {label} ----\n\n{text.strip()}\n")
    inventory.append(entry)
json.dump({"name": name, "source": release, "components": inventory},
          open(f"{notices}/third-party.json", "w"), indent=2, ensure_ascii=False)
with open(f"{notices}/THIRD_PARTY_LICENSES.txt", "w") as f:
    f.write(f"{name}\n\nThe native libraries in this package are built from the components below.\n"
            "mpv and FFmpeg are licensed under the LGPL and are linked dynamically. Their complete\n"
            f"corresponding source, with the build scripts, is published at\n{release}\n\n"
            "Portions of this software are copyright (C) The FreeType Project (https://freetype.org).\n"
            "All rights reserved.\n\n")
    for e in inventory:
        f.write(f"{e['name']} {e['version']}\n  Licence: {e['license']}\n  Homepage: {e['url']}\n"
                f"  In: {e['binaries']}\n  Licence text: {', '.join(e['licenseTexts'])}\n\n")
    f.write("\n".join(texts))
PY
rm "$notices/.components" "$notices/.libcxx-LICENSE.txt"
cp "$notices/THIRD_PARTY_LICENSES.txt" "$out/$name-THIRD_PARTY_LICENSES.txt"
cp "$notices/third-party.json" "$out/$name-third-party.json"

msg "Building the AAR"
LIBRARY_ONLY=1 ./buildall.sh -n

# the AAR must hold exactly the ABIs asked for, each with every library
want_abis=$(for arch in "${archs[@]}"; do abi "$arch"; done | sort | tr '\n' ' ')
have_abis=$(unzip -Z1 "$aar" 'jni/*' | awk -F/ 'NF > 2 { print $2 }' | sort -u | tr '\n' ' ')
[[ "$want_abis" == "$have_abis" ]] || die "The AAR has ABIs '$have_abis', expected '$want_abis'"
for a in $want_abis; do
	for l in mpv "${ffmpeg_libs[@]}" player c++_shared; do
		unzip -Z1 "$aar" "jni/$a/lib$l.so" >/dev/null || die "The AAR lacks jni/$a/lib$l.so"
	done
done
unzip -Z1 "$aar" assets/libmpv/THIRD_PARTY_LICENSES.txt >/dev/null || die "The AAR lacks its licence notices"
cp "$aar" "$out/$name.aar"

msg "Packing the corresponding source"
bundle=$(mktemp -d)
mkdir "$bundle/upstream"
(cd sources && sha256sum -c SHA256SUMS)
while read -r _ archive; do
	cp "sources/$archive" "$bundle/upstream/"
done <sources/SHA256SUMS
cp sources/SHA256SUMS "$bundle/upstream/"
git -C .. archive --format=tar --prefix=mpv-android/ HEAD | tar -xf - -C "$bundle"
cat >"$bundle/README.txt" <<EOF
Corresponding source for $name
$repo_url (commit $(git rev-parse HEAD))

upstream/      the exact source archives the build used, with their SHA-256 sums.
               libplacebo has no release archive; its tarball is the pinned git tag
               (commit $commit_libplacebo) with its submodules.
mpv-android/   the build scripts, patches, JNI glue and library module.

To rebuild (Linux; see mpv-android/buildscripts/README.md for the host packages):
    mkdir -p mpv-android/buildscripts/sources mpv-android/buildscripts/deps
    cp upstream/* mpv-android/buildscripts/sources/
    tar -xzf upstream/libplacebo-v$v_libplacebo.tar.gz -C mpv-android/buildscripts/deps
    cd mpv-android/buildscripts && ./katari-release.sh --build $build
The Android SDK and NDK ($v_ndk) are downloaded by the build from Google.
EOF
tar -cf "$out/$name-sources.tar" -C "$bundle" README.txt upstream mpv-android
rm -rf "$bundle"

msg "Writing checksums"
(cd "$out" && sha256sum -- "$name"* >"$name-SHA256SUMS.txt" && cat "$name-SHA256SUMS.txt")

msg "Native libraries in the AAR"
unzip -lv "$aar" 'jni/*'
ls -l "$out"
