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
    "$PROJECT_DIR/Sources/FocusLens/ActivityModels.swift" \
    "$PROJECT_DIR/Sources/FocusLens/RecognitionDiagnostics.swift" \
    "$PROJECT_DIR/Sources/FocusLens/Inactivity.swift" \
    "$PROJECT_DIR/Sources/FocusLens/Appearance.swift" \
    "$PROJECT_DIR/Sources/FocusLens/FloatingVisuals.swift" \
    "$PROJECT_DIR/Sources/FocusLens/VisionService.swift" \
    "$PROJECT_DIR/Sources/FocusLens/MemoryScreenCapture.swift" \
    "$PROJECT_DIR/Sources/FocusLens/FloatingScreenSupport.swift" \
    "$PROJECT_DIR/Sources/FocusLens/AutomaticTracker.swift" \
    "$PROJECT_DIR/Sources/FocusLens/ActivityFloating.swift" \
    "$PROJECT_DIR/Sources/FocusLens/AIService.swift" \
    "$PROJECT_DIR/Sources/FocusLens/Store.swift" \
    "$PROJECT_DIR/Sources/FocusLens/AutomaticSummary.swift" \
    "$PROJECT_DIR/Sources/FocusLens/ActivityPresentation.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/FocusLensTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/StreamingTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/AutomaticTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/UnrecognizedTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/InactivityTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/MultiscreenTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/AppearanceTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/AutomaticOnlyTests.swift" \
    "$PROJECT_DIR/Tests/FocusLensTests/CheckRunner.swift" \
    -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks" | tee "$CHECK_DIR/results"
if ! grep -q '项检查，0 个失败$' "$CHECK_DIR/results"; then
    print -u2 "检查进程未输出完整通过结果。"
    exit 1
fi
