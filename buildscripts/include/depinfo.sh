#!/bin/bash -e

## Dependency versions
# Make sure to keep v_ndk and v_ndk_n in sync, both are listed on the NDK download page

v_sdk=11076708_latest
v_ndk=r30
v_ndk_n=30.0.16248370
v_sdk_platform=36
v_sdk_build_tools=36.0.0

v_lua=5.2.4
v_dav1d=1.5.5
v_ffmpeg=9.0.2
v_unibreak=8.0
v_harfbuzz=15.0.0
v_fribidi=1.0.17
v_freetype=2.15.0
v_mbedtls=3.6.7
v_libxml2=2.15.4
v_fontconfig=2.18.3
v_curl=8.23.0
v_libass=0.17.5
v_libplacebo=7.387.0
v_mpv=0.42.0

## Source pins, checked by download-deps.sh
# release archives by SHA-256, git checkouts by commit

sha_mbedtls=a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6
sha_dav1d=ca96b1d0ba3f01f55de7231d775892b64994ba061aaeeaaa4f662a390b3abf9e
sha_ffmpeg=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
sha_freetype=93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
sha_fribidi=6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2
sha_harfbuzz=968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
sha_unibreak=9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4
sha_libxml2=98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821
sha_fontconfig=4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3
sha_libass=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
sha_lua=b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b
sha_curl=e3de77cfa6367083c776a26647fc9f633b538c06c3baa73d931a252ac8f72b49
sha_mpv=bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd
commit_libplacebo=275f7dea27924cdd34ab2e6c20e448b6bc4fab65


## Dependency tree

dep_mbedtls=()
dep_dav1d=()
dep_libxml2=()
dep_ffmpeg=(mbedtls dav1d libxml2)
dep_freetype2=()
dep_fontconfig=(libxml2 freetype2)
dep_fribidi=()
dep_harfbuzz=()
dep_unibreak=()
dep_libass=(freetype2 fontconfig fribidi harfbuzz unibreak)
dep_lua=()
dep_libplacebo=()
dep_curl=(mbedtls)
# lua and curl are not built: an embedding app needs no scripts, and FFmpeg does the HTTP
dep_mpv=(ffmpeg libass libplacebo)
dep_mpv_android=(mpv)


## for CI workflow

# pinned ffmpeg revision
v_ci_ffmpeg=n$v_ffmpeg

# filename used to uniquely identify a build prefix
ci_tarball="prefix-n${v_ndk}-l${v_lua}-u${v_unibreak}-h${v_harfbuzz}-fr${v_fribidi}-ft${v_freetype}-x${v_libxml2}-fo${v_fontconfig}-m${v_mbedtls}-c${v_curl}-ff${v_ci_ffmpeg}.tgz"
