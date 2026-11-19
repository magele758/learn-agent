#!/usr/bin/env bash
# 扫描一段提交：每个 commit 的提交信息、diff 新增行、新增文件名与大小。pre-push 与 CI 共用。
# 用法：scripts/scan-range.sh <git rev-list 参数…>   例：scripts/scan-range.sh origin/main..HEAD
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$(git -C "$here" rev-parse --show-toplevel)"
. "$here/lib/aep.sh"
. "$here/lib/security.sh"
[ $# -gt 0 ] || { echo "用法：$0 <git rev-list 参数…>" >&2; exit 2; }
sec_env
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scan-range.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

n=$(git rev-list --count "$@")
if [ "$n" = 0 ]; then echo "  · 没有需要扫描的提交"; exit 0; fi
echo "  · 扫描 $n 个提交"

git log -z --format='%H%n%B' "$@" > "$tmp/msgs"
sec_scan --input messages < "$tmp/msgs" || fail=1

git log --format='commit %h' --raw --no-abbrev --no-renames --diff-filter=AM "$@" \
  | awk -F '\t' '/^commit / { c = substr($0, 8); next } /^:/ { split($1, a, " "); print c "\t" a[4] "\t" $2 }' > "$tmp/added"
bad=$(cut -f3 "$tmp/added" | sec_bad_names | LC_ALL=C sort -u)
if [ -n "$bad" ]; then
  echo "  ✗ 这些提交加入了禁止入库的文件："
  printf '%s\n' "$bad" | sed 's/^/      /'
  fail=1
fi
big=$(awk -F '\t' '{ print $2 " " $1 " " $3 }' "$tmp/added" | sec_big_files)
if [ -n "$big" ]; then
  echo "  ✗ 这些提交加入了超过大小上限的文件："
  printf '%s\n' "$big"
  fail=1
fi

git log -p -U0 --no-color --no-ext-diff --format='commit %H' --diff-filter=AM "$@" > "$tmp/diff"
if sec_has_gitleaks; then
  if ! gitleaks git --no-banner --redact -v -l warn --log-opts="$*" . > "$tmp/gl" 2>&1; then
    echo "  ✗ gitleaks 发现疑似密钥："
    sed 's/^/      /' "$tmp/gl"
    fail=1
  fi
  sec_scan --input diff --no-secrets < "$tmp/diff" || fail=1
else
  sec_gitleaks_hint
  sec_scan --input diff < "$tmp/diff" || fail=1
fi
exit "$fail"
