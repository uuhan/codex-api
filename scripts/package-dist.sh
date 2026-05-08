#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CodexAPI.app"
DIST="$ROOT/dist"
VERSION="${VERSION:-1.0.1}"
ARCHIVE="$DIST/CodexAPI-$VERSION-macos.zip"

cd "$ROOT"
scripts/build-app.sh

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

cat > "$DIST/README.txt" <<'TXT'
CodexAPI

Open CodexAPI.app to start the menu-bar app.
The default local OpenAI-compatible base URL is:

  http://127.0.0.1:1455/v1

Use the menu-bar item to run Login OpenAI before sending upstream requests.
TXT

echo "Built $ARCHIVE"
