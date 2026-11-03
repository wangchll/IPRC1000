#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
sdk=${IPRC1000_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
cache_dir=/private/tmp/iprc1000-intel-module-cache
library_dir="$root_dir/Vendor/lib-intel"
variant=${IPRC1000_PACKAGE_VARIANT:-}
case "$variant" in
    ''|Local|GitHub-AdHoc) ;;
    *) print -u2 'IPRC1000_PACKAGE_VARIANT must be Local or GitHub-AdHoc'; exit 64 ;;
esac
app="$root_dir/dist/IPRC1000 Adapter Intel${variant:+ $variant}.app"
sign_identity=${IPRC1000_CODE_SIGN_IDENTITY:--}
if [[ "$variant" == GitHub-AdHoc && "$sign_identity" != - ]] || [[ "$variant" == Local && "$sign_identity" == - ]]; then
    print -u2 'GitHub-AdHoc requires ad-hoc signing; Local requires IPRC1000_CODE_SIGN_IDENTITY'
    exit 64
fi

if [[ ! -f "$library_dir/libsbc.a" ]]; then
    "$root_dir/scripts/build-libsbc-intel.sh"
fi

mkdir -p "$cache_dir"
SDKROOT="$sdk" \
CLANG_MODULE_CACHE_PATH="$cache_dir" \
SWIFT_MODULECACHE_PATH="$cache_dir" \
IPRC1000_SBC_LIBRARY_PATH="$library_dir" \
    swift build --package-path "$root_dir" --disable-sandbox -c release --sdk "$sdk" \
    --triple x86_64-apple-macosx14.0

bin_path=$(SDKROOT="$sdk" \
    CLANG_MODULE_CACHE_PATH="$cache_dir" \
    SWIFT_MODULECACHE_PATH="$cache_dir" \
    IPRC1000_SBC_LIBRARY_PATH="$library_dir" \
    swift build --package-path "$root_dir" --disable-sandbox -c release --sdk "$sdk" \
    --triple x86_64-apple-macosx14.0 --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/IPRC1000Adapter" "$app/Contents/MacOS/IPRC1000Adapter"
cp "$root_dir/NOTICE.md" "$app/Contents/Resources/NOTICE.md"
cp "$root_dir/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$root_dir/Vendor/Source/sbc-2.2.tar.xz" "$app/Contents/Resources/sbc-2.2.tar.xz"
cp "$root_dir/App/Assets/IPRC1000.icns" "$app/Contents/Resources/IPRC1000.icns"
cp "$root_dir/App/Assets/IPRC1000-Remote.png" "$app/Contents/Resources/IPRC1000-Remote.png"
cp "$root_dir/App/Info.plist" "$app/Contents/Info.plist"
cp "$root_dir/App/VoiceInputTest.html" "$app/Contents/Resources/VoiceInputTest.html"
helper="$app/Contents/Resources/WeChatInputHelper.app/Contents"
mkdir -p "$helper/MacOS" "$helper/Resources"
cp "$root_dir/Vendor/VibeStick/Info.plist" "$helper/Info.plist"
cp "$root_dir/Vendor/VibeStick/LICENSE" "$helper/Resources/LICENSE"
SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$cache_dir" SWIFT_MODULECACHE_PATH="$cache_dir" \
    swiftc -O -sdk "$sdk" -target x86_64-apple-macosx14.0 \
    "$root_dir/Vendor/VibeStick/wechat_input.swift" -o "$helper/MacOS/vibe_stick_wechat_input"
codesign --force --deep --sign "$sign_identity" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
