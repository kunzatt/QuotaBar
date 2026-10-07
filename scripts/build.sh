#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  xcodebuild \
    -project "$project_dir/QuotaBar.xcodeproj" \
    -scheme QuotaBar \
    -configuration Debug \
    -derivedDataPath /private/tmp/QuotaBarDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  cd "$project_dir"
  # Command Line Tools on newer macOS lack the SwiftUI macro plugin; borrow Xcode's when present.
  swift_flags=()
  xcode_plugins=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
  if [[ $(xcode-select -p 2>/dev/null) == /Library/Developer/CommandLineTools* && -f $xcode_plugins/libSwiftUIMacros.dylib ]]; then
    swift_flags=(-Xswiftc -plugin-path -Xswiftc "$xcode_plugins")
  fi
  swift build "${swift_flags[@]}"
fi
