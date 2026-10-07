#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
bundle_path="$project_dir/dist/QuotaBar.app"

cd "$project_dir"
# Command Line Tools on newer macOS lack the SwiftUI macro plugin; borrow Xcode's when present.
swift_flags=()
xcode_plugins=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
if [[ $(xcode-select -p 2>/dev/null) == /Library/Developer/CommandLineTools* && -f $xcode_plugins/libSwiftUIMacros.dylib ]]; then
  swift_flags=(-Xswiftc -plugin-path -Xswiftc "$xcode_plugins")
fi
swift build -c release "${swift_flags[@]}"

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
cp Resources/QuotaBar.icns "$bundle_path/Contents/Resources/QuotaBar.icns"
plutil -replace CFBundleExecutable -string QuotaBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.local.QuotaBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleName -string QuotaBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string en "$bundle_path/Contents/Info.plist"
cp .build/release/QuotaBar "$bundle_path/Contents/MacOS/QuotaBar"
chmod 755 "$bundle_path/Contents/MacOS/QuotaBar"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$bundle_path"
fi

plutil -lint "$bundle_path/Contents/Info.plist"
printf 'Created %s\n' "$bundle_path"
