#!/usr/bin/env bash
# 唯一验证入口，本地与 CI 共用：scripts/gate.sh fast|merge|full
# 范式继承文件。技术栈按清单文件自动适配（scripts/gate.d/<stack>.sh）；项目定制写在 scripts/gate.local.sh。
set -euo pipefail
cd "$(dirname "$0")/.."
GATE_ROOT=$(pwd -P)
. scripts/lib/aep.sh
GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX")
trap 'rm -rf "$GATE_TMP"' EXIT
export AEP_EVAL_STAMP=$GATE_TMP/eval.passed
tier=${1:-fast}

# 含任一清单文件的目录：仓库根优先；否则子目录（≤ 3 层），嵌套目录只保留最上层。
manifest_dirs() {
  local m expr=()
  for m in "$@"; do if [ -f "$m" ]; then echo .; return 0; fi; done
  for m in "$@"; do expr+=(-o -name "$m"); done
  find . -maxdepth 3 \
    \( -name .git -o -name node_modules -o -name target -o -name dist -o -name build -o -name .build \
       -o -name .venv -o -name venv -o -name vendor -o -name .worktrees -o -name examples -o -name fixtures \
       -o -name testdata -o -name docs -o -name third_party -o -name Pods \) -prune \
    -o -type f \( -false "${expr[@]}" \) -print 2>/dev/null \
    | sed 's|/[^/]*$||' | LC_ALL=C sort -u \
    | awk '{ for (i = 1; i <= n; i++) if (index($0, k[i] "/") == 1) next; k[++n] = $0; print }'
}

for f in scripts/gate.d/*.sh; do
  if [ -f "$f" ]; then . "$f"; fi
done

known_stacks() { local f; for f in scripts/gate.d/*.sh; do [ -f "$f" ] && basename "$f" .sh; done; return 0; }
detect_stacks() {
  local s out=""
  for s in $(known_stacks); do
    if type "${s}_detect" >/dev/null 2>&1 && [ -n "$("${s}_detect")" ]; then out="$out $s"; fi
  done
  echo "${out# }"
}
stack_dirs() {
  local var
  var=GATE_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_DIRS
  if [ -n "${!var:-}" ]; then echo "${!var}"; else "${1}_detect"; fi
}
stack_step() { # <lint|unit|integration|e2e|slow>：对每个识别到的技术栈与目录执行对应函数
  local s d ran=0
  for s in $GATE_STACKS; do
    type "${s}_$1" >/dev/null 2>&1 || continue
    for d in $(stack_dirs "$s"); do
      echo "  · $s（$d）"
      (cd "$d" && "${s}_$1")
      ran=1
    done
  done
  if [ "$ran" = 0 ]; then echo "  ⚠ 没有技术栈提供 $1（识别到：${GATE_STACKS:-无}；在 scripts/gate.local.sh 中配置）"; fi
  return 0
}

run_lint()        { stack_step lint; }
run_unit()        { stack_step unit; }
run_integration() { stack_step integration; }
run_e2e()         { stack_step e2e; }
run_slow()        { stack_step slow; }
run_eval() { # 有 evals/ 且配置了 runner 时跑全部数据集并与基线对比（evals/README.md），否则提示跳过
  if [ ! -d evals ]; then echo "  ▷ 跳过：没有 evals/（非 AI 项目或 spike 档）"; return 0; fi
  if [ ! -x scripts/eval-compare.sh ]; then echo "  ▷ 跳过：没有 scripts/eval-compare.sh（product 档提供）"; return 0; fi
  if [ -z "$(aep_conf eval_runner)" ]; then
    echo "  ▷ 跳过：未配置 eval runner（.agents/paradigm.conf 的 eval_runner，或在 scripts/gate.local.sh 中 export AEP_EVAL_RUNNER=…）"
    return 0
  fi
  if [ -f "$AEP_EVAL_STAMP" ]; then echo "  · 本次门禁已在 prompts 步骤跑过 eval 并通过，不重复运行"; return 0; fi
  scripts/eval-compare.sh --run
}

GATE_STACKS=${GATE_STACKS-}
if [ -f scripts/gate.local.sh ]; then . scripts/gate.local.sh; fi
[ -n "$GATE_STACKS" ] || GATE_STACKS=$(detect_stacks)

step() {
  local name=$1 t=$SECONDS
  shift
  echo "▶ $name"
  "$@"
  echo "  ✓ $name ($((SECONDS - t))s)"
}
optional() { # 当前档位没有该脚本时跳过
  local name=$1
  shift
  if [ -x "$1" ]; then step "$name" "$@"; else echo "▷ $name：未安装（$1）"; fi
}

fast() {
  echo "技术栈：${GATE_STACKS:-未识别}"
  step hygiene scripts/check-hygiene.sh
  optional rules scripts/rule-doctor.sh
  step lint run_lint
  step unit run_unit
}
merge() { fast; step integration run_integration; step e2e run_e2e; optional prompts scripts/check-prompts.sh; }
full()  { merge; step slow run_slow; step eval run_eval; }

case "$tier" in
  fast|merge|full) "$tier"; echo "✅ gate:$tier 通过" ;;
  *) echo "用法：$0 fast|merge|full" >&2; exit 2 ;;
esac
