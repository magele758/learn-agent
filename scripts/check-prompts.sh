#!/usr/bin/env bash
# prompt 改动门禁（gate.sh merge 调用）：相对 base 改动的 prompt 文件必须带版本标记并 bump，且 eval 与基线对比通过。
# 用法：scripts/check-prompts.sh [--base <ref>] [--no-eval]
#   prompt 目录：.agents/paradigm.conf 的 prompt_dirs（默认 prompts，空格分隔）；README* 与 _ / . 开头的文件不算 prompt
#   base：--base > 环境变量 GATE_BASE > origin/HEAD、origin/main、origin/master、main、master 与 HEAD 的 merge-base；
#         都找不到时把全部 prompt 文件视为改动
#   版本标记：前 10 行写 version: <N>（改内容必须 bump），或文件名带 .v<N>.（base 中已有的不能原地改，复制为新版本）
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/aep.sh
die() { echo "check-prompts：$*" >&2; exit 2; }

base_ref=${GATE_BASE:-} no_eval=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || die "--base 需要一个 ref"; base_ref=$2; shift 2 ;;
    --no-eval) no_eval=1; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

dirs=()
for d in $(aep_conf prompt_dirs prompts); do if [ -d "$d" ]; then dirs+=("$d"); fi; done
if [ "${#dirs[@]}" -eq 0 ]; then echo "  · 没有 prompt 目录（$(aep_conf prompt_dirs prompts)），跳过"; exit 0; fi
git rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库，无法判断 prompt 改动"

base=""
if [ -n "$base_ref" ]; then
  git rev-parse --verify -q "$base_ref^{commit}" >/dev/null || die "base「$base_ref」不是有效的提交（CI 的 checkout 需要 fetch-depth: 0）"
  base=$(git merge-base HEAD "$base_ref" 2>/dev/null || git rev-parse "$base_ref^{commit}")
else
  for c in origin/HEAD origin/main origin/master main master; do
    if git rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1 && base=$(git merge-base HEAD "$c" 2>/dev/null); then break; fi
    base=""
  done
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
g() { git -c core.quotePath=false "$@"; }
if [ -n "$base" ]; then
  { g diff --name-only "$base" -- "${dirs[@]}"; g ls-files -o --exclude-standard -- "${dirs[@]}"; } | LC_ALL=C sort -u > "$list"
  where="相对 $(git rev-parse --short "$base")"
else
  g ls-files -co --exclude-standard -- "${dirs[@]}" | LC_ALL=C sort -u > "$list"
  where="找不到 base（设置 GATE_BASE=<ref>），按全部 prompt 文件处理"
fi

changed=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$(basename "$f")" in README*|_*|.*) continue ;; esac
  changed+=("$f")
done < "$list"
if [ "${#changed[@]}" -eq 0 ]; then echo "  · prompt 未改动（$where），跳过"; exit 0; fi
echo "  · prompt 改动（$where）：${changed[*]}"

head_version() { # 前 10 行的 version: <值>（YAML / 注释 / JSON 写法都认）
  awk -v q="'" 'NR > 10 { exit }
    match($0, "^[^[:alnum:]]*version[\"" q "]?[[:space:]]*:[[:space:]]*") {
      v = substr($0, RSTART + RLENGTH); gsub("[\"" q ",]", "", v); sub(/[[:space:]].*$/, "", v)
      if (v != "") { print v; exit }
    }' "$@"
}
name_version() { basename "$1" | sed -nE 's/.*\.v([0-9]+)(\..*)?$/\1/p'; }

errs=0
for f in "${changed[@]}"; do
  if [ ! -f "$f" ]; then echo "  · $f：已删除"; continue; fi
  nv=$(name_version "$f")
  hv=$(head_version "$f")
  if [ -z "$nv" ] && [ -z "$hv" ]; then
    echo "  ✗ $f：没有版本标记（前 10 行写 version: <N>，或文件名带 .v<N>.）"; errs=$((errs + 1)); continue
  fi
  if [ -z "$base" ] || ! git cat-file -e "$base:$f" 2>/dev/null; then continue; fi
  if [ -n "$nv" ]; then
    echo "  ✗ $f：带版本号的文件在 base 中已存在，不能原地修改：复制为 .v$((nv + 1)). 的新文件并改引用，旧版本留作回滚"
    errs=$((errs + 1))
  elif [ "$(git show "$base:$f" 2>/dev/null | head_version || true)" = "$hv" ]; then
    echo "  ✗ $f：内容改了但 version 仍是 $hv：bump 版本"; errs=$((errs + 1))
  fi
done
if [ "$errs" -gt 0 ]; then echo "  prompt 版本标记：$errs 处问题"; exit 1; fi
[ "$no_eval" = 0 ] || exit 0

if [ -z "$(aep_conf eval_runner)" ]; then
  echo "  ✗ 改动了 prompt，但没有配置 eval runner：在 .agents/paradigm.conf 写 eval_runner=<命令>（约定见 evals/README.md），"
  echo "    用 scripts/eval-compare.sh --run 跑通（首次加 --update-baseline 建立基线）后再提交"
  exit 1
fi
if [ ! -x scripts/eval-compare.sh ]; then echo "  ✗ 改动了 prompt，但没有 scripts/eval-compare.sh（product 档提供）"; exit 1; fi
echo "  · prompt 改动必须通过 eval 基线对比："
scripts/eval-compare.sh --run
