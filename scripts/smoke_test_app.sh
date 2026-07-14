#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-.build/distribution/Glimpse.app}"
APP_NAME="${APP_NAME:-Glimpse}"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
LOG_PATH="$(mktemp "${TMPDIR:-/tmp}/glimpse-startup.XXXXXX.log")"
PROCESS_ID=""

cleanup() {
    if [[ -n "$PROCESS_ID" ]] && kill -0 "$PROCESS_ID" 2>/dev/null; then
        kill "$PROCESS_ID" 2>/dev/null || true
        wait "$PROCESS_ID" 2>/dev/null || true
    fi
    rm -f "$LOG_PATH"
}
trap cleanup EXIT

[[ -x "$EXECUTABLE" ]] || {
    echo "App executable not found at $EXECUTABLE" >&2
    exit 1
}

"$EXECUTABLE" >"$LOG_PATH" 2>&1 &
PROCESS_ID=$!

for _ in {1..20}; do
    if ! kill -0 "$PROCESS_ID" 2>/dev/null; then
        wait "$PROCESS_ID" || exit_code=$?
        echo "Glimpse exited during startup with status ${exit_code:-0}." >&2
        cat "$LOG_PATH" >&2
        exit 1
    fi
    sleep 0.25
done

echo "App startup smoke test passed."
