#!/bin/bash -e

. ./include/depinfo.sh

[ -z "$IN_CI" ] && IN_CI=0
[ -z "$WGET" ] && WGET=wget

# Every source is pinned (see depinfo.sh). The archives are kept in sources/ so that
# a release can publish exactly what was built.
mkdir -p deps sources

sha256 () {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# fetch <dir> <url> <sha256> [<archive name>]
fetch () {
	local dir=deps/$1 archive=sources/${4:-${2##*/}}
	[ -d "$dir" ] && return 0
	if [ ! -f "$archive" ]; then
		$WGET "$2" -O "$archive.part"
		mv "$archive.part" "$archive"
	fi
	local actual
	actual=$(sha256 "$archive")
	if [[ "$actual" != "$3" ]]; then
		printf >&2 'Checksum mismatch for %s:\n  expected %s\n  got      %s\n' "$archive" "$3" "$actual"
		exit 1
	fi
	mkdir "$dir"
	tar -xf "$archive" -C "$dir" --strip-components=1
}

# fetch_git <dir> <url> <tag> <commit> [<submodule>...]
# Also packs the checkout (with its submodules) into sources/, since there is no release archive.
fetch_git () {
	local dir=deps/$1 url=$2 tag=$3 commit=$4
	shift 4
	[ -d "$dir" ] && return 0
	git clone --depth 1 -b "$tag" "$url" "$dir"
	local actual
	actual=$(git -C "$dir" rev-parse HEAD)
	if [[ "$actual" != "$commit" ]]; then
		printf >&2 'Commit mismatch for %s %s:\n  expected %s\n  got      %s\n' "$url" "$tag" "$commit" "$actual"
		rm -rf "$dir"
		exit 1
	fi
	[ $# -gt 0 ] && git -C "$dir" submodule update --init --depth 1 -- "$@"
	tar -cf - --exclude=.git -C deps "${dir#deps/}" | gzip -n >"sources/${dir#deps/}-$tag.tar.gz"
}

fetch mbedtls https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$v_mbedtls/mbedtls-$v_mbedtls.tar.bz2 $sha_mbedtls

fetch dav1d https://downloads.videolan.org/pub/videolan/dav1d/$v_dav1d/dav1d-$v_dav1d.tar.xz $sha_dav1d

fetch ffmpeg https://ffmpeg.org/releases/ffmpeg-$v_ffmpeg.tar.xz $sha_ffmpeg

fetch freetype2 https://download.savannah.gnu.org/releases/freetype/freetype-$v_freetype.tar.xz $sha_freetype

fetch fribidi https://github.com/fribidi/fribidi/releases/download/v$v_fribidi/fribidi-$v_fribidi.tar.xz $sha_fribidi

fetch harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/$v_harfbuzz/harfbuzz-$v_harfbuzz.tar.xz $sha_harfbuzz

fetch unibreak https://github.com/adah1972/libunibreak/releases/download/libunibreak_${v_unibreak//./_}/libunibreak-${v_unibreak}.tar.gz $sha_unibreak

fetch libxml2 https://download.gnome.org/sources/libxml2/${v_libxml2%.*}/libxml2-$v_libxml2.tar.xz $sha_libxml2

fetch fontconfig https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/$v_fontconfig/fontconfig-$v_fontconfig.tar.xz $sha_fontconfig

fetch libass https://github.com/libass/libass/releases/download/$v_libass/libass-$v_libass.tar.xz $sha_libass

# the demos submodule is left out, demos aren't built
fetch_git libplacebo https://github.com/haasn/libplacebo v$v_libplacebo $commit_libplacebo \
	3rdparty/{glad,jinja,markupsafe,fast_float,Vulkan-Headers}

fetch mpv https://github.com/mpv-player/mpv/archive/$v_mpv.tar.gz $sha_mpv mpv-$v_mpv.tar.gz
