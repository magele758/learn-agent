#!/usr/bin/env bash
# 静态验收门禁：approved/implemented 的每条 AC 必须被至少一个测试标题 [AC:<id>#AC-n] 引用，或在 eval: 中引用存在的数据集
# （evals/README.md；有当前提交生成的 eval 结果时还检查 min_pass_rate）；测试不得引用不存在的 AC。
# ACC_EVAL_MODE=warn 时 min_pass_rate 不达标只提示（rule-doctor 用：结果可能早于工作区的改动）。
# 进阶做法：再读取 JUnit 结果，要求带标签测试实际运行且通过。
set -euo pipefail
cd "$(dirname "$0")/.."
ACC_DIR=${ACC_DIR:-acceptance}
ACC_EVAL_MODE=${ACC_EVAL_MODE:-fail}
EVAL_RESULT=${EVAL_RESULT:-artifacts/evals/latest.json}
EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target --exclude-dir=dist
          --exclude-dir=.venv --exclude-dir=.worktrees --exclude-dir="$ACC_DIR" --exclude-dir=docs)
FS=$(printf '\037')

known=$(mktemp); tags=$(mktemp); evals=$(mktemp); refs=$(mktemp)
trap 'rm -f "$known" "$tags" "$evals" "$refs"' EXIT
fail=0; pending=0; covered=0; by_eval=0

eval_refs() { # <yaml> → 每条带 eval: 的标准一行：AC-n、dataset、min_pass_rate、未知字段（\037 分隔）
  awk -v fs="$FS" -v q="'" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function unq(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ ("^" q ".*" q "$")) s = substr(s, 2, length(s) - 2)
      return s
    }
    function kv(s,   k, v) {
      k = s; sub(/:.*/, "", k); k = unq(k)
      v = s; if (!sub(/^[^:]*:/, "", v)) v = ""
      v = unq(v)
      if (k == "dataset") ds = v; else if (k == "min_pass_rate") min = v; else if (k != "") bad = bad (bad == "" ? "" : ",") k
    }
    function flush() { if (ac != "" && has) print ac fs ds fs min fs bad; has = blk = 0; ds = min = bad = "" }
    /^[[:space:]]*(#.*)?$/ { next }
    /^[^[:space:]-]/ { flush(); ac = ""; next }
    /^[[:space:]]*-[[:space:]]*id:/ && match($0, /AC-[0-9]+/) { flush(); ac = substr($0, RSTART, RLENGTH); next }
    blk && ind($0) > eind { l = $0; sub(/[[:space:]]+#.*$/, "", l); kv(l); next }
    { blk = 0 }
    ac != "" && /^[[:space:]]+eval:/ {
      has = 1; eind = ind($0); e = $0
      sub(/^[[:space:]]*eval:[[:space:]]*/, "", e); sub(/[[:space:]]+#.*$/, "", e)
      if (e == "") blk = 1
      else if (e ~ /^\{.*\}$/) { n = split(substr(e, 2, length(e) - 2), parts, ","); for (i = 1; i <= n; i++) kv(parts[i]) }
      else ds = unq(e)
      next
    }
    END { flush() }' "$1"
}

shopt -s nullglob
for f in "$ACC_DIR"/*.yaml "$ACC_DIR"/*.yml; do
  case "$(basename "$f")" in _*) continue ;; esac
  id=$(sed -nE 's/^id:[[:space:]]*"?([A-Za-z0-9_.-]+)"?.*/\1/p' "$f" | head -1)
  status=$(sed -nE 's/^status:[[:space:]]*([a-z]+).*/\1/p' "$f" | head -1)
  if [ -z "$id" ]; then echo "✗ $f：缺少顶层 id"; fail=1; continue; fi
  acs=$(sed -nE 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*"?(AC-[0-9]+)"?.*/\1/p' "$f")
  dup=$(printf '%s\n' "$acs" | sort | uniq -d)
  if [ -n "$dup" ]; then echo "✗ $f：重复的标准 id：$dup"; fail=1; fi
  eval_refs "$f" > "$evals"
  for ac in $acs; do
    echo "$id#$ac" >> "$known"
    ds="" min="" bad="" has_eval=0
    if IFS=$FS read -r _ ds min bad < <(awk -F "$FS" -v ac="$ac" '$1 == ac { print; f = 1; exit } END { exit !f }' "$evals"); then
      has_eval=1; ds=${ds#./}
    fi
    case "$status" in
      approved|implemented)
        if [ "$has_eval" = 1 ]; then
          if [ -n "$bad" ]; then echo "✗ $id#$ac 的 eval 有未知字段：$bad（只支持 dataset、min_pass_rate）"; fail=1
          elif [ -z "$ds" ]; then echo "✗ $id#$ac 的 eval 缺少 dataset"; fail=1
          elif [ ! -f "$ds" ]; then echo "✗ $id#$ac 引用的 eval 数据集不存在：$ds"; fail=1
          else
            covered=$((covered + 1)); by_eval=$((by_eval + 1))
            printf '%s\t%s\t%s\n' "$id#$ac" "$ds" "$min" >> "$refs"
          fi
        elif grep -rqF "${EXCLUDES[@]}" -- "[AC:$id#$ac]" .; then
          covered=$((covered + 1))
        else
          echo "✗ $id#$ac（$status）没有任何带标签的测试，也没有引用 eval"; fail=1
        fi ;;
      draft)
        pending=$((pending + 1))
        if [ "$has_eval" = 1 ] && [ -n "$ds" ] && [ ! -f "$ds" ]; then echo "  ⚠ $id#$ac（draft）引用的 eval 数据集还不存在：$ds"; fi ;;
    esac
  done
done

grep -rhoE "${EXCLUDES[@]}" '\[AC:[A-Za-z0-9_.-]+#AC-[0-9]+\]' . 2>/dev/null \
  | sed -E 's/^\[AC:(.*)\]$/\1/' | sort -u > "$tags" || true
while read -r t; do
  [ -n "$t" ] || continue
  grep -qxF "$t" "$known" || { echo "✗ 测试引用了不存在的标准：[AC:$t]"; fail=1; }
done < "$tags"

if [ -s "$refs" ]; then
  if [ -f scripts/lib/eval.pl ]; then
    perl scripts/lib/eval.pl acceptance "$refs" "$EVAL_RESULT" "$ACC_EVAL_MODE" || fail=1
  else
    echo "  ⚠ 没有 scripts/lib/eval.pl：跳过 eval 数据集格式与 min_pass_rate 检查"
  fi
fi

echo "  验收：已覆盖 $covered 条$([ "$by_eval" = 0 ] || echo "（其中 eval $by_eval 条）")，待确认(draft) $pending 条"
exit "$fail"
