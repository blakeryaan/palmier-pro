#!/bin/bash
# scripts/dev.sh — build the debug bundle, launch it, and stream its OSLog.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stream=true
for arg in "$@"; do
    case "$arg" in
        --no-stream) stream=false ;;
    esac
done

"$ROOT/scripts/bundle.sh" debug --fast

if ! $stream; then
    open "$ROOT/.build/HoTFEditor.app"
    exit 0
fi

echo "Streaming OSLog (subsystem=com.thehotf.editor). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "HoTFEditor.app/Contents/MacOS/HoTFEditor" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "HoTFEditor"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$ROOT/.build/HoTFEditor.app" ) &
log stream \
    --predicate 'subsystem == "com.thehotf.editor"' \
    --level info \
    --style compact
