#!/usr/bin/env bash
# Installs a pinned XcodeGen into .tools/ and generates LeanType.xcodeproj.
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]] || [[ "$("$XCODEGEN" --version)" != *"$XCODEGEN_VERSION"* ]]; then
  mkdir -p "$TOOLS"
  curl -sSL -o "$TOOLS/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
  rm "$TOOLS/xcodegen.zip"
fi

"$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT"
