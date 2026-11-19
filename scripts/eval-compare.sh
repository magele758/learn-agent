#!/usr/bin/env bash
# eval 基线对比：当前结果 vs evals/baseline.json。通过率比基线低出阈值即失败；成本 / 延迟 p95 超出阈值按 eval_on_budget 失败或告警。
# 用法：scripts/eval-compare.sh [--run] [--current <结果.json>] [--baseline <基线.json>] [--update-baseline]
#   --run              先用 eval runner 跑 evals/datasets/*.jsonl（_ 开头的示例除外），合并写入 artifacts/evals/latest.json；
#                      对比之后再用 check-acceptance 检查验收里 eval 引用的 min_pass_rate
#   --current          要对比的结果：latest.json，或单个数据集的标准 JSON（默认 artifacts/evals/latest.json）
#   --update-baseline  把当前结果写入基线（显式操作，提交时写明原因），不因回退失败
# runner 与阈值在 .agents/paradigm.conf 配置（环境变量 AEP_<KEY 大写> 优先），约定见 evals/README.md。
# 退出码：0 通过；1 回退 / 超出预算 / 结果不合约定 / runner 失败；2 用法或配置错误。
set -euo pipefail
here=$(pwd -P)
cd "$(dirname "$0")/.."
. scripts/lib/aep.sh
die() { echo "eval-compare：$*" >&2; exit 2; }
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$here/$1" ;; esac; }

LATEST=artifacts/evals/latest.json
run=0 update=0 current="" baseline=evals/baseline.json
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=1; shift ;;
    --update-baseline) update=1; shift ;;
    --current) [ $# -ge 2 ] || die "--current 需要一个文件"; current=$(abs "$2"); shift 2 ;;
    --baseline) [ $# -ge 2 ] || die "--baseline 需要一个文件"; baseline=$(abs "$2"); shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done
[ "$run" = 0 ] || [ -z "$current" ] || die "--run 与 --current 只能用其一"

run_all() { # 每个数据集调用一次 runner：<runner> <数据集>，stdout 为标准 JSON
  local runner ds out pairs=()
  runner=$(aep_conf eval_runner)
  [ -n "$runner" ] || die "没有配置 eval runner：在 .agents/paradigm.conf 写 eval_runner=<命令>（或 export AEP_EVAL_RUNNER=…），约定见 evals/README.md"
  mkdir -p artifacts/evals/runs
  for ds in evals/datasets/*.jsonl; do
    [ -f "$ds" ] || continue
    case "$(basename "$ds")" in _*) continue ;; esac
    out=artifacts/evals/runs/$(basename "$ds" .jsonl).json
    echo "  · 运行 $ds"
    if ! AEP_EVAL_DATASET=$ds bash -c "$runner"' "$@"' eval-runner "$ds" > "$out"; then
      echo "  ✗ runner 失败（$ds）：$runner"
      exit 1
    fi
    pairs+=("$ds" "$out")
  done
  [ "${#pairs[@]}" -gt 0 ] || die "evals/datasets/ 下没有数据集（_ 开头的是示例，不参与运行）"
  perl scripts/lib/eval.pl collect "$LATEST" "${pairs[@]}"
}

[ "$run" = 0 ] || run_all
current=${current:-$LATEST}
[ -f "$current" ] || die "没有可对比的结果：$current（先运行 scripts/eval-compare.sh --run）"
opt=()
[ "$update" = 0 ] || opt=(--update)
rc=0
EVAL_MAX_DROP=$(aep_conf eval_max_pass_rate_drop 0.05) EVAL_MAX_COST_INC=$(aep_conf eval_max_cost_increase 0.2) \
EVAL_MAX_P95_INC=$(aep_conf eval_max_p95_increase 0.5) EVAL_MAX_COST=$(aep_conf eval_max_cost) \
EVAL_MAX_P95_MS=$(aep_conf eval_max_p95_ms) EVAL_ON_BUDGET=$(aep_conf eval_on_budget fail) \
  perl scripts/lib/eval.pl compare "$current" "$baseline" ${opt[@]+"${opt[@]}"} || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
if [ "$run" = 1 ] && [ "$update" = 0 ] && [ -x scripts/check-acceptance.sh ] && [ -d acceptance ]; then
  scripts/check-acceptance.sh | sed 's/^ */  /' || rc=1
fi
if [ "$rc" = 0 ] && [ -n "${AEP_EVAL_STAMP:-}" ]; then : > "$AEP_EVAL_STAMP"; fi
exit "$rc"
