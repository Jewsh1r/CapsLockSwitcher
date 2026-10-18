#!/bin/bash
# Builds a universal CapsLockSwitcher.app without Xcode (Command Line Tools are enough).
# Output: build/CapsLockSwitcher.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

NAME=CapsLockSwitcher
BUNDLE_ID=com.doasync.CapsLockSwitcher
MIN_MACOS=13.0
APP="build/$NAME.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" \
    -o "build/$NAME-$arch" "$NAME/main.swift" "$NAME/AppDelegate.swift"
done
lipo -create -output "$APP/Contents/MacOS/$NAME" "build/$NAME-arm64" "build/$NAME-x86_64"
rm "build/$NAME-arm64" "build/$NAME-x86_64"

sed -e "s/\$(EXECUTABLE_NAME)/$NAME/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    -e "s/\$(PRODUCT_NAME)/$NAME/" \
    -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/" \
    "$NAME/Info.plist" > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'CapsLock Switcher'" \
                        -c "Add :CFBundleIconFile string $NAME" \
                        -c "Add :LSApplicationCategoryType string public.app-category.utilities" \
                        "$APP/Contents/Info.plist"
cp "$NAME/$NAME.icns" "$APP/Contents/Resources/"

codesign --force --options runtime --entitlements "$NAME/$NAME.entitlements" --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
