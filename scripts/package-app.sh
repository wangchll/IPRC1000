#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
cache_dir=/private/tmp/iprc1000-module-cache
app="$root_dir/dist/IPRC1000 Adapter.app"
sign_identity=${IPRC1000_CODE_SIGN_IDENTITY:--}

mkdir -p "$cache_dir"
SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$cache_dir" SWIFT_MODULECACHE_PATH="$cache_dir" \
    swift build --disable-sandbox -c release --sdk "$sdk"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root_dir/.build/arm64-apple-macosx/release/IPRC1000Adapter" \
    "$app/Contents/MacOS/IPRC1000Adapter"
cp "$root_dir/NOTICE.md" "$app/Contents/Resources/NOTICE.md"
cp "$root_dir/Vendor/Source/sbc-2.2.tar.xz" "$app/Contents/Resources/sbc-2.2.tar.xz"
cp "$root_dir/App/Assets/IPRC1000.icns" "$app/Contents/Resources/IPRC1000.icns"
cp "$root_dir/App/Assets/IPRC1000-Remote.png" "$app/Contents/Resources/IPRC1000-Remote.png"
cp "$root_dir/App/Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign "$sign_identity" "$app"
echo "$app"
