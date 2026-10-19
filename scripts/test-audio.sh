#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wisprduck-audio-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TEST_PRIVATE_FRAMEWORKS="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
TEST_LIBRARIES="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib"

xcrun swiftc -parse-as-library \
  -F "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$TEST_PRIVATE_FRAMEWORKS" \
  -I "$TEST_LIBRARIES" -L "$TEST_LIBRARIES" -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$ROOT_DIR/WisprDuck/AudioCoordinator.swift" \
  "$ROOT_DIR/tests/AudioCoordinatorTests.swift" \
  -o "$TEST_DIR/audio-tests"
"$TEST_DIR/audio-tests"
