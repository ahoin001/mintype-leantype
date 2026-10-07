#!/usr/bin/env bash
# Rebuilds Packages/LeanTypeKit/Sources/LeanTypeCore/Resources/lexicon.bin from the
# FrequencyWords English full list (OpenSubtitles 2018, CC BY-SA 4.0), capped at 100k words.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/lexicon"
source_url="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt"
output="$root/Packages/LeanTypeKit/Sources/LeanTypeCore/Resources/lexicon.bin"

mkdir -p "$work" "$(dirname "$output")"
if [[ ! -f "$work/en_full.txt" ]]; then
  curl -sSfL -o "$work/en_full.txt" "$source_url"
fi

case_reference=()
if [[ -f /usr/share/dict/words ]]; then
  case_reference=(--case-reference /usr/share/dict/words)
fi

swift run -c release --package-path "$root/Tools/LexiconBuilder" LexiconBuilder \
  "$work/en_full.txt" "$output" \
  --blocklist "$root/Tools/LexiconBuilder/blocklist.txt" \
  --limit 100000 \
  "${case_reference[@]}"
