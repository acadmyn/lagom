#!/usr/bin/env bash
# push main and create one GitHub issue per file in tools/issues (skips titles that already exist)
set -euo pipefail
cd "$(dirname "$0")/.."
git push origin main
existing="$(gh issue list --state all --limit 200 --json title --jq '.[].title')"
for f in tools/issues/*.md; do
  title="$(head -n1 "$f")"
  if grep -Fxq "$title" <<<"$existing"; then echo "exists: $title"; continue; fi
  tail -n +2 "$f" | gh issue create --title "$title" --body-file -
done
