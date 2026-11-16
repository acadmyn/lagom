#!/usr/bin/env bash
# sync lagom to the norns, (re)load it, and show matron output
set -euo pipefail
HOST="${NORNS_SSH:-we@norns.tretiotre.local}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

rsync -a --delete --exclude .git --exclude tools --exclude '*.md' "$DIR/" "$HOST:/home/we/dust/code/lagom/"
python3 "$DIR/tools/repl.py" -t "${WAIT:-4}" 'norns.script.load("/home/we/dust/code/lagom/lagom.lua")'
