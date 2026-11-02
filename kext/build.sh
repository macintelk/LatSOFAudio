#!/bin/zsh
# Build a single-file C++ kext without Xcode: build-kext.sh <Name>
# Source: <Name>/*.cpp + <Name>/*.c + Info.plist  ->  build/<Name>.kext
# Everything the build produces stays in build/ : the product in build/<Name>.kext,
# intermediates in build/obj/... which are removed again on exit.
#
# Also builds the userspace companion tool if its source is present:
#   latsof-default-input/latsof-default-input.c  ->  latsof-default-input/latsof-default-input
# (universal x86_64 + arm64, ad-hoc signed, CoreAudio only). If the tool
# source dir is missing the kext is still built and a note is printed.
#
# LAYOUT WARNING: keep latsof-default-input/ a SIBLING of LatSOFAudio/,
# never inside it. The kext link line below globs LatSOFAudio/*.c, so a
# userspace .c dropped into the kext source dir would get compiled into
# the kernel binary and the link would fail (or worse, "succeed").
set -e
NAME=LatSOFAudio
TOOL=latsof-default-input
ROOT=${0:A:h}
SRC=$ROOT/$NAME
OUT=$ROOT/$NAME.kext
TSRC=$ROOT/$TOOL
TBIN=$TSRC/$TOOL
TMP=$ROOT/$NAME/$$
SDK=$(xcrun --show-sdk-path)
KH=$SDK/System/Library/Frameworks/Kernel.framework/Headers

trap 'rm -rf $TMP' EXIT INT TERM
rm -rf $OUT
mkdir -p $OUT/Contents/MacOS $TMP
cp $SRC/Info.plist $OUT/Contents/Info.plist

BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $SRC/Info.plist)
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $SRC/Info.plist)
INFO=$TMP/kmod_info.c
cat > $INFO <<EOC
#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL($BID, "$VER", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOC
clang -arch x86_64 -mkernel -nostdinc -fno-builtin -fno-common -mmacosx-version-min=14.0 \
  -DKERNEL -I$KH -isystem $KH -c $INFO -o $TMP/kmod_info.o

set -- $SRC/*.cpp(N) $SRC/*.c(N)  $SRC/*.s(N)
clang++ -arch x86_64 -std=gnu++17 -O2 -Wno-deprecated-declarations \
  -mkernel -nostdlib -nostdinc -nostdinc++ \
  -fno-builtin -fno-exceptions -fno-rtti -fno-common -fapple-kext \
  -mmacosx-version-min=14.0 \
  -D__KERNEL__ -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -I$KH -isystem $KH \
  -Xlinker -kext -Xlinker -export_dynamic \
  -lkmod -lkmodc++ -lcc_kext \
  "$@" $TMP/kmod_info.o -o $OUT/Contents/MacOS/$NAME

codesign -v -f -s - $OUT/Contents/MacOS/$NAME
echo "built $OUT"

# --------------------------------------------------------------------------
# Userspace tool: latsof-default-input
#
# Plain CoreAudio CLI, no kernel flags, no Kernel.framework. Built exactly
# like `make` in the tool dir would: universal (x86_64 + arm64), C11,
# ad-hoc signature. -Wno-deprecated-declarations silences the
# kAudioObjectPropertyElementMaster rename warning on newer SDKs.
# --------------------------------------------------------------------------
if [[ -f $TSRC/$TOOL.c ]]; then
  clang -O2 -Wall -Wextra -Wno-deprecated-declarations -std=c11 \
    -arch x86_64 -arch arm64 \
    -isysroot $SDK -mmacosx-version-min=11.0 \
    -o $TBIN $TSRC/$TOOL.c \
    -framework CoreAudio -framework CoreFoundation
  codesign -v -f -s - $TBIN
  echo "built $TBIN"
else
  echo "note: $TSRC/$TOOL.c not found - skipped latsof-default-input"
fi
