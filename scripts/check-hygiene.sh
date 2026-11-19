#!/usr/bin/env bash
# 仓库卫生与安全：敏感文件名、超大文件、冲突标记、密钥与私有信息（Tailscale IP / tailnet 主机名 / 个人路径 / 私有模式）。
# 用法：scripts/check-hygiene.sh [--staged | --untracked]
#   --staged 供 pre-commit 使用，只检查暂存内容；默认检查已跟踪文件；--untracked 再加上未跟踪（未被忽略）的文件
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo "$here/..")"
. "$here/lib/aep.sh"
. "$here/lib/security.sh"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "  ⚠ 非 git 仓库，跳过卫生检查"; exit 0; }
sec_env
mode=${1:-tracked}
case "$mode" in --staged|tracked|--untracked) ;; *) echo "用法：$0 [--staged | --untracked]" >&2; exit 2 ;; esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hygiene.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
grep_scope=()

case "$mode" in
  --staged)
    git diff --cached --name-only --diff-filter=ACMR > "$tmp/files"
    grep_scope=(--cached) ;;
  tracked) git ls-files > "$tmp/files" ;;
  --untracked)
    git ls-files -co --exclude-standard > "$tmp/files"
    grep_scope=(--untracked) ;;
esac
[ -s "$tmp/files" ] || exit 0

bad=$(sec_bad_names < "$tmp/files")
if [ -n "$bad" ]; then
  echo "  ✗ 禁止入库的文件（密钥 / 凭据 / agent 会话 / 浏览器 profile 等）："
  printf '%s\n' "$bad" | sed 's/^/      /'
  fail=1
fi

if [ "$mode" = --staged ]; then
  big=$(tr '\n' '\0' < "$tmp/files" | xargs -0 git ls-files -s -- | awk -F "\t" '{ split($1, a, " "); print a[2], $2 }' | sec_big_files)
else
  big=$(sec_big_files --paths < "$tmp/files")
fi
if [ -n "$big" ]; then
  echo "  ✗ 超过大小上限的文件（.agents/paradigm.conf 的 max_file_kb，或环境变量 AEP_MAX_FILE_KB）："
  printf '%s\n' "$big"
  fail=1
fi

if [ "$mode" = --staged ]; then
  markers=$(tr '\n' '\0' < "$tmp/files" | xargs -0 git grep --cached -nIE '^(<<<<<<<|>>>>>>>)( |$)' -- 2>/dev/null || true)
else
  markers=$(git grep "${grep_scope[@]+"${grep_scope[@]}"}" -nIE '^(<<<<<<<|>>>>>>>)( |$)' 2>/dev/null || true)
fi
if [ -n "$markers" ]; then
  echo "  ✗ 残留的合并冲突标记："
  printf '%s\n' "$markers" | cut -d: -f1,2 | sed 's/^/      /'
  fail=1
fi

if [ "$mode" = --staged ]; then
  git diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR > "$tmp/diff"
  if sec_has_gitleaks; then
    if ! gitleaks git --staged --no-banner --redact -v -l warn . > "$tmp/gl" 2>&1; then
      echo "  ✗ gitleaks 发现疑似密钥："
      sed 's/^/      /' "$tmp/gl"
      fail=1
    fi
    sec_scan --input diff --no-secrets < "$tmp/diff" || fail=1
  else
    sec_gitleaks_hint
    sec_scan --input diff < "$tmp/diff" || fail=1
  fi
else
  sec_grep_tree "${grep_scope[@]+"${grep_scope[@]}"}" > "$tmp/grep"
  sec_scan --input grep < "$tmp/grep" || fail=1
fi

if [ "$fail" != 0 ]; then
  echo "  处理：移出仓库或改为环境变量 / 占位值；测试用明显的假值，必要时登记 .agents/security-allowlist 或 .gitleaksignore。"
fi
exit "$fail"
