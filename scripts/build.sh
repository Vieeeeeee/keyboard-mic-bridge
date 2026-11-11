#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/keyboard-mic-bridge-build.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
app_dir="$build_dir/KeyboardMicBridge.app"
mkdir -p "$app_dir/Contents/MacOS" "$project_dir/dist"
cp "$project_dir/resources/Info.plist.template" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources" && cp "$project_dir/resources/AppIcon.icns" "$app_dir/Contents/Resources/"
plutil -lint "$app_dir/Contents/Info.plist"
xcrun swiftc -O -warnings-as-errors -module-cache-path "$build_dir/module-cache" \
  "$project_dir/src/KeyboardMicBridge.swift" -o "$app_dir/Contents/MacOS/KeyboardMicBridge"
"$app_dir/Contents/MacOS/KeyboardMicBridge" --self-test
# Build outside cloud-backed folders to avoid resource-fork signing failures.
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k --keepParent "$app_dir" "$build_dir/KeyboardMicBridge-experimental.zip"
unzip -tq "$build_dir/KeyboardMicBridge-experimental.zip"
mv "$build_dir/KeyboardMicBridge-experimental.zip" "$project_dir/dist/KeyboardMicBridge-experimental.zip"
printf 'Built: %s/dist/KeyboardMicBridge-experimental.zip\n' "$project_dir"
