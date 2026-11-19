#!/usr/bin/env bash
# eval 参考 runner（零依赖）：逐条把数据集的 input 写到被测命令的 stdin，按 criteria 判定 stdout，向 stdout 输出标准 JSON。
# 用法：scripts/eval-run.sh --cmd '<被测命令>' [--timeout <秒，默认 60>] [--cost-unit <单位，默认 USD>] <数据集.jsonl>
#   被测命令在仓库根用 sh -c 执行，可读环境变量 AEP_EVAL_CASE_ID / AEP_EVAL_DATASET；在 stderr 输出一行
#   AEP_EVAL_COST=<数值> 即上报本条成本。criteria：exact | contains | regex | json。约定见 evals/README.md。
set -euo pipefail
here=$(pwd -P)
cd "$(dirname "$0")/.."
case "${1:-}" in -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
AEP_CALLER_PWD=$here exec perl scripts/lib/eval.pl run "$@"
