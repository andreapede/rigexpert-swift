#!/bin/bash
# Runs the AntScopeKit test suite.
#
# Swift Testing ships inside the Command Line Tools but SwiftPM only wires up its
# search paths when a full Xcode is selected, so point at them explicitly. Once
# Xcode is installed and `xcode-select`ed, plain `swift test` works and this
# script becomes redundant.
set -euo pipefail

DEVELOPER_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
DEVELOPER_LIB="$(xcode-select -p)/Library/Developer/usr/lib"

if [ ! -d "$DEVELOPER_FRAMEWORKS/Testing.framework" ]; then
  exec swift test --package-path "$(dirname "$0")" "$@"
fi

exec swift test \
  --package-path "$(dirname "$0")" \
  --disable-xctest --enable-swift-testing \
  -Xswiftc -F -Xswiftc "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -F -Xlinker "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$DEVELOPER_LIB" \
  "$@"
