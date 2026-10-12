#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
CHECK_DIR="$(mktemp -d -t focuslens-checks)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/FocusLens/Models.swift" \
    "$PROJECT_DIR/Sources/FocusLens/AIService.swift" \
    "$PROJECT_DIR/Sources/FocusLens/Store.swift" \
    "$PROJECT_DIR/Sources/FocusLens/FloatingTimer.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/FocusLensTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/CheckRunner.swift" \
    -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
