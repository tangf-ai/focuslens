#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-${PROJECT_DIR}/.artifacts/automatic-only-preview}"
TEMP_DIR="$(mktemp -d -t focuslens-preview)"
trap 'rm -rf "$TEMP_DIR"' EXIT
sed '/^@main$/d' "$PROJECT_DIR/Sources/FocusLens/App.swift" > "$TEMP_DIR/App.swift"
SOURCES=("$PROJECT_DIR"/Sources/FocusLens/*.swift)
SOURCES=("${(@)SOURCES:#*/App.swift}")
swiftc -parse-as-library -swift-version 5 "${SOURCES[@]}" "$TEMP_DIR/App.swift" "$PROJECT_DIR/scripts/NativePreview.swift" -o "$TEMP_DIR/preview"
"$TEMP_DIR/preview" "$OUTPUT_DIR"
