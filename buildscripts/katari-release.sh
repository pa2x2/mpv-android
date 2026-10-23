#!/bin/bash -e

# Builds a Katari libmpv release into buildscripts/release/:
# - libmpv-android-<version>.aar: libmpv, FFmpeg and the JNI glue (MPVLib) for each ABI,
#   with the licence notices as assets/libmpv/
# - ...-sources.tar: the LGPL corresponding source, i.e. the exact upstream archives the
#   build used plus this repository's build scripts
# - ...-THIRD_PARTY_LICENSES.txt, ...-third-party.json: the licence inventory and texts
# - ...-licence-evidence.txt: the licence settings read back from the build
# - ...-load-order.json: the order in which a host loads the libraries, per ABI (MPVLib doesn't
#   load them), generated from their DT_NEEDED entries; also in the AAR as assets/libmpv/
# - katari-mpv-<abi>-<version>.apk: the Katari mpv add-on (app.katari.mpv) for each ABI, an APK
#   with no code holding the AAR's libraries and assets/libmpv/, built by ../katari-addon
# - ...-SHA256SUMS.txt
# It also fails if the JNI glue changed without a new MPVLib.GLUE_LEVEL (see katari-glue.py).
# .github/workflows/katari-release.yml only runs this script. Needs bash 4, python3 and a JDK.
#
# Usage: ./katari-release.sh [--arch <arch>]... [--version <version>] [--release]
#   --arch     armv7l, arm64 or x86_64, repeatable (default: all three)
#   --version  the release version; the workflow passes the part of the tag after "libmpv-"
#              (default: dev). The mpv and FFmpeg versions are in the notices, not in this.
#   --release  a build to publish (the workflow passes it for tags): the version must be a
#              release version (see version_code), and the APKs are signed with the key in
#              KATARI_KEYSTORE (a keystore file), KATARI_KEYSTORE_PASSWORD, KATARI_KEY_ALIAS
#              and KATARI_KEY_PASSWORD, which must all be set. Otherwise the APKs are signed
#              with the Android debug key (~/.android/debug.keystore), like local Katari builds.

cd "$( dirname "${BASH_SOURCE[0]}" )"
. ./include/depinfo.sh
. ./include/path.sh

# the signing key's settings, out of the environment so the dependencies' builds don't see them
ks_file=$KATARI_KEYSTORE ks_pass=$KATARI_KEYSTORE_PASSWORD
key_alias=$KATARI_KEY_ALIAS key_pass=$KATARI_KEY_PASSWORD
unset KATARI_KEYSTORE KATARI_KEYSTORE_PASSWORD KATARI_KEY_ALIAS KATARI_KEY_PASSWORD

archs=()
version=dev
release=
while [ $# -gt 0 ]; do
	case "$1" in
		--arch) shift; archs+=("$1") ;;
		--version) shift; version=$1 ;;
		--release) release=1 ;;
		*) echo "Unknown argument $1" >&2; exit 1 ;;
	esac
	shift
done
[ ${#archs[@]} -eq 0 ] && archs=(armv7l arm64 x86_64)

name=libmpv-android-$version
# the repository the release is published from: GitHub Actions sets these, locally it's origin
if [ -n "$GITHUB_REPOSITORY" ]; then
	repo_url=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY
else
	repo_url=$(git remote get-url origin)
	repo_url=${repo_url%.git}
fi
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

# The add-on's versionCode. A release version is YYYY-MM-DD-N, the date of the release and a
# counter N from 1 to 99 without leading zeros, and gets YYYYMMDD * 100 + N: 2026-10-23-2 is
# 2026102302. So the codes go up as long as no release is tagged with an earlier date than the
# last one; --release checks that against the tags already pushed. Other versions are for local
# builds only: YYYY-MM-DD-<anything else> (e.g. 2026-10-23-test) gets YYYYMMDD * 100, below that
# day's releases, and dev gets 1. Anything else fails.
version_code () { # <version> [release]
	local v=$1
	if [[ "$v" =~ ^(20[0-9]{2})-([0-9]{2})-([0-9]{2})-(.+)$ ]]; then
		local date=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]} n=${BASH_REMATCH[4]}
		python3 -c 'import datetime, sys; datetime.date.fromisoformat(sys.argv[1])' \
			"${v:0:10}" 2>/dev/null || return 1
		if [[ "$n" =~ ^[1-9][0-9]?$ ]]; then
			echo $(( 10#$date * 100 + n ))
		elif [ -z "$2" ]; then
			echo $(( 10#$date * 100 ))
		else
			return 1
		fi
	elif [[ "$v" == dev && -z "$2" ]]; then
		echo 1
	else
		return 1
	fi
}

[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "Invalid version '$version'"
version_code=$(version_code "$version" ${release:+release}) || die \
	"The version '$version' has no add-on versionCode: releases are YYYY-MM-DD-N, N from 1 to 99"
for arch in "${archs[@]}"; do abi "$arch" >/dev/null; done
if [ -n "$release" ]; then
	# a later release must get a larger versionCode, or Android won't update the add-on to it
	tags=$(git ls-remote --tags origin 'refs/tags/libmpv-*') || die "Can't list the tags of origin"
	while read -r _ ref; do
		tag=${ref#refs/tags/libmpv-} tag=${tag%^\{\}}
		code=$(version_code "$tag" release) || continue
		[[ "$tag" == "$version" || $code -lt $version_code ]] ||
			die "libmpv-$tag has the versionCode $code, not less than $version_code for $version"
	done <<<"$tags"
fi

# The JNI glue level the AAR's MPVLib declares; katari-glue.py checks it against classes.jar.
glue=$(sed -n 's/^ *const val GLUE_LEVEL: Int = \([1-9][0-9]*\)$/\1/p' \
	../libmpv/src/main/java/is/xyz/mpv/MPVLib.kt)
[[ "$glue" =~ ^[1-9][0-9]*$ ]] || die "Can't read GLUE_LEVEL from MPVLib.kt"

# The key that signs the add-on, and its certificate's SHA-256, which the APKs must have.
keytool=${JAVA_HOME:+$JAVA_HOME/bin/}keytool
if [ -n "$release" ]; then
	for v in ks_file:KATARI_KEYSTORE ks_pass:KATARI_KEYSTORE_PASSWORD key_alias:KATARI_KEY_ALIAS \
			key_pass:KATARI_KEY_PASSWORD; do
		n=${v%%:*}
		[ -n "${!n}" ] || die "--release signs with Katari's key, but ${v#*:} isn't set"
	done
	[ -s "$ks_file" ] || die "The keystore $ks_file is missing or empty"
else
	ks_file=${ANDROID_USER_HOME:-$HOME/.android}/debug.keystore ks_pass=android
	key_alias=androiddebugkey key_pass=android
	if [ ! -e "$ks_file" ]; then
		# what the Android Gradle plugin creates for local builds
		mkdir -p "$(dirname "$ks_file")"
		"$keytool" -genkeypair -keystore "$ks_file" -storepass android -alias androiddebugkey \
			-keypass android -keyalg RSA -keysize 2048 -validity 10950 \
			-dname 'CN=Android Debug,O=Android,C=US'
	fi
fi
export KS_PASS=$ks_pass KEY_PASS=$key_pass
cert=$("$keytool" -exportcert -rfc -keystore "$ks_file" -storepass:env KS_PASS -alias "$key_alias") ||
	die "Can't read the certificate of '$key_alias' in $ks_file"
unset KS_PASS KEY_PASS
cert=$("$keytool" -J-Duser.language=en -printcert <<<"$cert")
if [ -n "$release" ] && grep -q '^Owner: .*CN=Android Debug' <<<"$cert"; then
	die "--release must not sign with an Android debug key"
fi
cert=$(sed -n 's/^\s*SHA256: //p' <<<"$cert" | tr -d : | tr A-F a-f)
[[ "$cert" =~ ^[0-9a-f]{64}$ ]] || die "Can't read the certificate's SHA-256"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	die "The working tree has uncommitted changes, so the source bundle wouldn't match the build"
fi

msg "Building $name for ${archs[*]} (add-on versionCode $version_code, glue level $glue)"
rm -rf "$out" "$notices" ../katari-addon/build
mkdir -p "$out" "$notices"

msg "Fetching the SDK, NDK and sources"
./download.sh

tools=$ANDROID_HOME/build-tools/$v_sdk_build_tools
# signature schemes v2 (as Katari's APKs) and v3; minSdk 29 needs no v1, incremental installs no v4
sign_apk () { # <in> <out>
	KS_PASS=$ks_pass KEY_PASS=$key_pass "$tools/apksigner" sign --ks "$ks_file" \
		--ks-pass env:KS_PASS --ks-key-alias "$key_alias" --key-pass env:KEY_PASS \
		--min-sdk-version 29 --v1-signing-enabled false --v2-signing-enabled true \
		--v3-signing-enabled true --v4-signing-enabled false --out "$2" "$1"
}
# try the key on an empty APK now, so that a wrong key password fails before the build
probe=$(mktemp -d)
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").writestr("probe", "")' \
	"$probe/unsigned.apk"
sign_apk "$probe/unsigned.apk" "$probe/signed.apk" 2>/dev/null ||
	die "Can't sign with the key '$key_alias' in $ks_file: is KATARI_KEY_PASSWORD right?"
rm -rf "$probe"

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

msg "Building the JNI glue"
NATIVE_ONLY=1 ./buildall.sh -n

msg "Writing the load order"
want_abis=$(for arch in "${archs[@]}"; do abi "$arch"; done | sort | tr '\n' ' ')
toolchain=$(echo "$ndk/toolchains/llvm/prebuilt/"*)
# the libraries may only need the system libraries of the oldest Android the AAR supports
api=$(sed -n 's/^APP_PLATFORM := android-//p' ../libmpv/src/main/jni/Application.mk)
abi_args=()
for a in $want_abis; do abi_args+=(--abi "$a"); done
load_order () {
	./katari-load-order.py --readelf "$toolchain/bin/llvm-readelf" --sysroot "$toolchain/sysroot" \
		--api "$api" --version "$version" --version-code "$version_code" --glue "$glue" \
		"${abi_args[@]}" "$1"
}
load_order ../libmpv/src/main/libs >"$notices/load-order.json"
cp "$notices/load-order.json" "$out/$name-load-order.json"
cat "$notices/load-order.json"

msg "Building the AAR"
LIBRARY_ONLY=1 ./buildall.sh -n

# the AAR must hold exactly the ABIs asked for, each with every library
have_abis=$(unzip -Z1 "$aar" 'jni/*' | awk -F/ 'NF > 2 { print $2 }' | sort -u | tr '\n' ' ')
[[ "$want_abis" == "$have_abis" ]] || die "The AAR has ABIs '$have_abis', expected '$want_abis'"
for a in $want_abis; do
	for l in mpv "${ffmpeg_libs[@]}" player c++_shared; do
		unzip -Z1 "$aar" "jni/$a/lib$l.so" >/dev/null || die "The AAR lacks jni/$a/lib$l.so"
	done
done
unzip -Z1 "$aar" assets/libmpv/THIRD_PARTY_LICENSES.txt >/dev/null || die "The AAR lacks its licence notices"
# and the load order must describe the libraries as packaged
jni=$(mktemp -d)
unzip -q "$aar" 'jni/*' -d "$jni"
unzip -p "$aar" assets/libmpv/load-order.json | cmp -s - "$notices/load-order.json" ||
	die "The AAR's assets/libmpv/load-order.json differs from the one written"
load_order "$jni/jni" | cmp -s - "$notices/load-order.json" ||
	die "The load order of the AAR's libraries differs from assets/libmpv/load-order.json"
rm -rf "$jni"
cp "$aar" "$out/$name.aar"

msg "Checking the JNI glue (level $glue)"
./katari-glue.py check --aar "$aar" --level "$glue" --readelf "$toolchain/bin/llvm-readelf"

msg "Building the mpv add-on"
addon=../katari-addon/build
mkdir -p "$addon/aar"
unzip -q "$aar" 'jni/*' 'assets/*' -d "$addon/aar"
(cd .. && ./gradlew :katari-addon:assembleRelease -PkatariVersion="$version" \
	-PkatariVersionCode="$version_code" -PkatariGlue="$glue" -PkatariAbis="$(tr ' ' , <<<"${want_abis% }")")
# the entries of a zip file under a directory, without the directory: <zip> <dir>
entries () { unzip -Z1 "$1" "$2/*" | grep -v '/$' | sed "s|^$2/||" | sort; }
check_addon () { # <abi> <apk>
	local a=$1 apk=$2 manifest e
	# signed only with the expected key, and the libraries page-aligned
	[ "$("$tools/apksigner" verify --print-certs "$apk" | grep '^Signer .* SHA-256 digest: ')" == \
		"Signer #1 certificate SHA-256 digest: $cert" ] || die "$apk isn't signed with $ks_file"
	"$tools/zipalign" -c -P 16 4 "$apk" || die "$apk isn't aligned"
	# the AAR's libraries for its ABI and its assets, byte for byte, and no code
	[ "$(entries "$apk" "lib/$a")" == "$(entries "$aar" "jni/$a")" ] ||
		die "$apk doesn't have the libraries of the AAR's jni/$a/"
	[ "$(unzip -Z1 "$apk" 'lib/*' | grep -v "^lib/$a/")" == "" ] || die "$apk has other ABIs"
	for e in $(entries "$aar" "jni/$a"); do
		cmp -s <(unzip -p "$apk" "lib/$a/$e") <(unzip -p "$aar" "jni/$a/$e") ||
			die "$apk: lib/$a/$e differs from the AAR's"
	done
	[ "$(entries "$apk" assets)" == "$(entries "$aar" assets)" ] || die "$apk lacks the AAR's assets"
	for e in $(entries "$aar" assets); do
		cmp -s <(unzip -p "$apk" "assets/$e") <(unzip -p "$aar" "assets/$e") ||
			die "$apk: assets/$e differs from the AAR's"
	done
	! unzip -Z1 "$apk" | grep -q '\.dex$' || die "$apk has code"
	# the manifest
	"$tools/aapt2" dump badging "$apk" | grep -q "^launchable-activity" && die "$apk has a launcher entry"
	manifest=$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk" |
		sed 's/^ *//; s/ (Raw: .*//; s/ (line=[0-9]*)$//')
	for e in 'A: package="app.katari.mpv"' \
			"A: http://schemas.android.com/apk/res/android:versionCode(0x0101021b)=$version_code" \
			"A: http://schemas.android.com/apk/res/android:versionName(0x0101021c)=\"$version\"" \
			'A: http://schemas.android.com/apk/res/android:hasCode(0x0101000c)=false' \
			'A: http://schemas.android.com/apk/res/android:extractNativeLibs(0x010104ea)=true'; do
		grep -qxF "$e" <<<"$manifest" || die "$apk: the manifest lacks $e"
	done
	grep -qE '^E: (activity|activity-alias|service|receiver|provider)$' <<<"$manifest" &&
		die "$apk has components"
	# the meta-data: the version as a string, the glue level as an integer
	grep -A2 -xF 'E: meta-data' <<<"$manifest" | grep -v -e '^E: meta-data$' -e '^--$' | paste - - |
		sed 's|A: http://schemas.android.com/apk/res/android:||g' >"$addon/meta-data.txt"
	diff -u - "$addon/meta-data.txt" <<-EOF || die "$apk has the wrong meta-data"
		name(0x01010003)="katari.libmpv.version"	value(0x01010024)="$version"
		name(0x01010003)="katari.libmpv.glue"	value(0x01010024)=$glue
	EOF
}
for a in $want_abis; do
	apk=$out/katari-mpv-$a-$version.apk
	sign_apk "$addon/outputs/apk/release/katari-addon-$a-release-unsigned.apk" "$apk"
	check_addon "$a" "$apk"
done
apks=("$addon"/outputs/apk/release/*.apk)
[ ${#apks[@]} -eq "$(wc -w <<<"$want_abis")" ] ||
	die "The add-on build made other APKs than one per ABI: ${apks[*]}"

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
    cd mpv-android/buildscripts && ./katari-release.sh --version $version
The Android SDK and NDK ($v_ndk) are downloaded by the build from Google.
EOF
tar -cf "$out/$name-sources.tar" -C "$bundle" README.txt upstream mpv-android
rm -rf "$bundle"

msg "Writing checksums"
(cd "$out" && sha256sum -- "$name"* katari-mpv-*.apk >"$name-SHA256SUMS.txt" && cat "$name-SHA256SUMS.txt")

msg "Native libraries in the AAR"
unzip -lv "$aar" 'jni/*'
msg "The mpv add-on"
for a in $want_abis; do "$tools/apksigner" verify --print-certs "$out/katari-mpv-$a-$version.apk"; done
ls -l "$out"
