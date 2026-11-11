#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/Config/Local.xcconfig" ]] || cp "$ROOT/Config/Local.xcconfig.example" "$ROOT/Config/Local.xcconfig"
if [[ -f "$ROOT/Config/TelegramConfiguration.local.plist" ]]; then
  cp "$ROOT/Config/TelegramConfiguration.local.plist" "$ROOT/Velagram/Resources/TelegramConfiguration.plist"
elif [[ ! -f "$ROOT/Velagram/Resources/TelegramConfiguration.plist" ]]; then
  cp "$ROOT/Config/TelegramConfiguration.example.plist" "$ROOT/Velagram/Resources/TelegramConfiguration.plist"
fi
