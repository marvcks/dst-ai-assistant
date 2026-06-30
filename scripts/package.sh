#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST="$ROOT/dist"
STAGE="$DIST/dst_ai_assistant"

rm -rf "$DIST"
mkdir -p "$STAGE"
cp -R "$ROOT/mod/." "$STAGE/"
rm -f "$STAGE/response.lua.tmp"

cd "$DIST"
zip -qr dst_ai_assistant-1.0.0.zip dst_ai_assistant
echo "$DIST/dst_ai_assistant-1.0.0.zip"
