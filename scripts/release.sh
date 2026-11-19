#!/usr/bin/env bash
# 用法：scripts/release.sh patch|minor|major [--dry-run]
# bump VERSION → 同步语言清单 → 从 Release-Note trailer 生成 CHANGELOG → commit + tag（不推送）
set -euo pipefail
cd "$(dirname "$0")/.."
bump=${1:?用法：release.sh patch|minor|major [--dry-run]}
dry=${2:-}

[ -n "$dry" ] || [ -z "$(git status --porcelain)" ] || { echo "工作区不干净，先提交或清理" >&2; exit 1; }

IFS=. read -r ma mi pa < VERSION
case "$bump" in
  major) ma=$((ma + 1)); mi=0; pa=0 ;;
  minor) mi=$((mi + 1)); pa=0 ;;
  patch) pa=$((pa + 1)) ;;
  *) echo "bump 只能是 patch|minor|major" >&2; exit 2 ;;
esac
next="$ma.$mi.$pa"
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
range=${last:+$last..}HEAD

rs=$(printf '\036'); fs=$(printf '\037')
log=$(git log --format="%s${fs}%(trailers:key=Release-Note,valueonly,separator= )${rs}" "$range")

section() { # $1 = feat | fix | other
  printf '%s' "$log" | awk -v RS="$rs" -F "$fs" -v mode="$1" '
    { sub(/^[\n]+/, "", $1); note = $2; gsub(/[\n]+/, " ", note); sub(/[ ]+$/, "", note)
      if (note == "") next
      t = ($1 ~ /^feat/) ? "feat" : (($1 ~ /^fix/) ? "fix" : "other")
      brk = ($1 ~ /^[a-z]+(\([^)]*\))?!:/) ? "**Breaking** " : ""
      if (t == mode) print "- " brk note }'
}

block=$(mktemp); trap 'rm -f "$block"' EXIT
{
  echo "## [$next] - $(date +%F)"
  for pair in "feat:Added" "fix:Fixed" "other:Changed"; do
    items=$(section "${pair%%:*}")
    [ -z "$items" ] || printf '\n### %s\n%s\n' "${pair#*:}" "$items"
  done
  echo
} > "$block"

if [ "$dry" = "--dry-run" ]; then echo "v$next（自 ${last:-首次提交}）"; cat "$block"; exit 0; fi

echo "$next" > VERSION
[ -f package.json ]   && perl -0pi -e 's/("version"\s*:\s*")[^"]+/${1}'"$next"'/' package.json
[ -f Cargo.toml ]     && perl -0pi -e 's/(\[package\][^\[]*?\nversion\s*=\s*")[^"]+/${1}'"$next"'/s' Cargo.toml
[ -f pyproject.toml ] && perl -0pi -e 's/(\nversion\s*=\s*")[^"]+/${1}'"$next"'/' pyproject.toml

n=$(grep -n '^## \[[0-9]' CHANGELOG.md | head -1 | cut -d: -f1 || true)
if [ -n "$n" ]; then
  { head -n $((n - 1)) CHANGELOG.md; cat "$block"; tail -n +"$n" CHANGELOG.md; } > CHANGELOG.md.tmp
else
  { cat CHANGELOG.md; echo; cat "$block"; } > CHANGELOG.md.tmp
fi
mv CHANGELOG.md.tmp CHANGELOG.md

for f in VERSION CHANGELOG.md package.json Cargo.toml pyproject.toml; do [ -f "$f" ] && git add "$f"; done
git commit -m "chore(release): v$next"
git tag -a "v$next" -m "v$next"
echo "已创建 v$next。检查 CHANGELOG 后执行：git push --follow-tags"
