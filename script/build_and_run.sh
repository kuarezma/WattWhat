#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="WattWhat"
BUNDLE_ID="com.kuarezma.wattwhat"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/WattWhat.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/WattWhat"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
./build.swift

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "Kullanım: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
