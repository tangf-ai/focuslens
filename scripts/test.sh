#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
CHECK_DIR="$(mktemp -d -t focuslens-checks)"
cleanup() {
    if [[ -n "${FOCUSLENS_STREAM_SERVER_PID:-}" ]]; then
        kill "$FOCUSLENS_STREAM_SERVER_PID" 2>/dev/null || true
        wait "$FOCUSLENS_STREAM_SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$CHECK_DIR"
}
trap cleanup EXIT
/usr/bin/python3 "$PROJECT_DIR/Tests/FocusLensTests/StreamServer.py" "$CHECK_DIR/port" &
FOCUSLENS_STREAM_SERVER_PID=$!
for ATTEMPT in {1..100}; do
    [[ -s "$CHECK_DIR/port" ]] && break
    sleep 0.05
done
export FOCUSLENS_TEST_PORT="$(cat "$CHECK_DIR/port")"
swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/FocusLens/Models.swift" \
    "$PROJECT_DIR/Sources/FocusLens/AIService.swift" \
    "$PROJECT_DIR/Sources/FocusLens/Store.swift" \
    "$PROJECT_DIR/Sources/FocusLens/FloatingTimer.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/FocusLensTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/StreamingTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/CheckRunner.swift" \
    -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
