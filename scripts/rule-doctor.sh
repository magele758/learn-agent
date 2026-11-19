#!/usr/bin/env bash
# 规则体检：规则之间、规则与执行点之间是否一致。由 scripts/gate.sh fast 调用。
# 用法：scripts/rule-doctor.sh [--strict] [--only <检查 id>]
#       scripts/rule-doctor.sh --render [enforcement.yaml …]   输出规则 → 执行点对照表（markdown）
# 豁免：在命中行或上一行写 “rule-doctor: allow <检查 id> <理由>”，理由必填。
set -euo pipefail
ORIG_PWD=$PWD
cd "$(dirname "$0")/.."
. scripts/lib/aep.sh

ERRORS=0
WARNS=0
STRICT=0
ONLY=""
FS=$(printf '\037')
NEG='不[[:space:]`]|不要|不得|不能|不可|不许|不准|禁止|严禁|切勿|勿|禁令|拦截|仅限人工|[Nn]ever|NEVER|[Dd]o not|[Dd]on.t|must not|MUST NOT|forbid|denied'
PH='\{\{[#/]?(PROJECT_NAME|STACK|OWNER|MAIN_PORTS|MAIN_PORTS_LINES|AGENT_PORTS|product|platform)\}\}'

err()  { ERRORS=$((ERRORS + 1)); echo "  ✗ [$1] $2"; }
warn() { WARNS=$((WARNS + 1)); echo "  ⚠ [$1] $2"; }
info() { echo "  · $1"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
clip() { local s; s=$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//'); [ "${#s}" -le 90 ] && printf '%s' "$s" || printf '%s…' "${s:0:90}"; }

enforcement_files() { local f; for f in .agents/enforcement.yaml .agents/enforcement.project.yaml; do if [ -f "$f" ]; then echo "$f"; fi; done; }

parse_enforcement() { # yaml… → 每条规则一行：id rule enforce check profile note（\037 分隔）
  awk -v fs="$FS" -v q="'" '
    function flush() { if (id != "") print id fs rule fs enf fs chk fs prof fs note; id = rule = enf = chk = prof = note = "" }
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+$/, "", s); if (s ~ ("^[\"" q "]")) s = substr(s, 2, length(s) - 2); return s }
    /^[[:space:]]*-[[:space:]]+id:/ { flush(); id = val($0); next }
    /^[[:space:]]+rule:/    { rule = val($0); next }
    /^[[:space:]]+enforce:/ { enf = val($0); next }
    /^[[:space:]]+check:/   { chk = val($0); next }
    /^[[:space:]]+profile:/ { prof = val($0); next }
    /^[[:space:]]+note:/    { note = val($0); next }
    END { flush() }' "$@"
}

render() {
  local files=() f
  for f in "$@"; do case "$f" in /*) files+=("$f") ;; *) files+=("$ORIG_PWD/$f") ;; esac; done
  if [ "${#files[@]}" -eq 0 ]; then while IFS= read -r f; do files+=("$f"); done < <(enforcement_files); fi
  [ "${#files[@]}" -gt 0 ] || { echo "没有 enforcement yaml" >&2; return 1; }
  echo "| 规则 | 执行方式 | 执行点 | 档位 | id |"
  echo "|---|---|---|---|---|"
  parse_enforcement "${files[@]}" | awk -F "$FS" '{
    m = ($3 == "hook") ? "hook 硬拦" : ($3 == "gate") ? "门禁" : ($3 == "ci") ? "CI" : ($3 == "lint") ? "lint" : "**建议**"
    c = ""; n = split($4, a, " "); for (i = 1; i <= n; i++) c = c (i > 1 ? " " : "") "`" a[i] "`"
    if (c == "") c = ($6 != "") ? $6 : "—"
    print "| " $2 " | " m " | " c " | " $5 " | `" $1 "` |" }'
}

allowed() { # <检查 id> <文件> <行号>：本行或上一行有带理由的豁免注释
  local id=$1 file=$2 n=$3 l line reason
  for l in "$n" "$((n - 1))"; do
    [ "$l" -ge 1 ] || continue
    line=$(sed -n "${l}p" "$file")
    case "$line" in *"rule-doctor: allow $id"*|*"rule-doctor:allow $id"*) ;; *) continue ;; esac
    reason=$(printf '%s' "$line" | sed -E "s/.*rule-doctor: ?allow $id//; s/-->.*//; s/^[[:space:]:：—-]*//; s/[[:space:]]*\$//")
    if [ "${#reason}" -lt 2 ]; then err "$id" "$file:$l 的豁免缺少理由（写成：rule-doctor: allow $id <理由>）"; fi
    return 0
  done
  return 1
}

doc_files() {
  aep_files | grep -E '^(AGENTS\.md|CLAUDE\.md|README\.md|.+/AGENTS\.md|\.cursor/rules/.+\.mdc|\.agents/skills/.+\.md|\.claude/.+\.md|docs/.+\.md)$' \
    | grep -vxF docs/enforcement.md || true
}

check_deny_cmd() {
  local list label pattern file hit n text files
  files=$(doc_files)
  for list in .agents/deny-commands.txt .agents/deny-commands.project.txt "$(aep_config_dir)/deny-commands.txt"; do
    [ -f "$list" ] || continue
    label=$list
    case "$list" in /*) label=个人禁令 ;; esac
    while IFS= read -r pattern || [ -n "$pattern" ]; do
      case "$pattern" in ''|'#'*) continue ;; esac
      while IFS= read -r file; do
        if [ ! -f "$file" ] || [ -L "$file" ]; then continue; fi
        while IFS= read -r hit; do
          n=${hit%%:*}
          text=${hit#*:}
          if grep -Eq -- "$NEG" <<< "$text"; then continue; fi
          if allowed deny-cmd "$file" "$n"; then continue; fi
          err deny-cmd "$file:$n 要求执行被禁止的命令（/$pattern/，$label）：$(clip "$text")"
        done < <(grep -nE -- "$pattern" "$file" 2>/dev/null || true)
      done <<< "$files"
    done < "$list"
  done
}

check_ci_advisory() {
  local f hit n
  for f in .github/workflows/*.yml .github/workflows/*.yaml .gitlab-ci.yml .gitlab/ci/*.yml; do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
      n=${hit%%:*}
      if allowed ci-advisory "$f" "$n"; then continue; fi
      err ci-advisory "$f:$n 设置了 $(clip "${hit#*:}")，门禁失败也不会拦截（确属参考性质：job 名加 (advisory)，并在该行写 rule-doctor: allow ci-advisory <理由>）"
    done < <(grep -nE '^[[:space:]]*(continue-on-error|allow_failure)[[:space:]]*:[[:space:]]*true' "$f" || true)
  done
}

check_placeholder() {
  local files f hit rules
  if [ -f .paradigm/lock ]; then files=$(awk '$1 == "own" { print $2 }' .paradigm/lock); else files="AGENTS.md README.md"; fi
  for f in $(printf '%s\n' $files .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS | LC_ALL=C sort -u); do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
      err placeholder "$f:${hit%%:*} 模板占位符未填写：$(clip "${hit#*:}")"
    done < <(grep -nE "$PH" "$f" || true)
  done
  for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    [ -f "$f" ] || continue
    rules=$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)
    if [ -z "$rules" ]; then warn placeholder "$f 没有任何负责人规则"; continue; fi
    while IFS= read -r hit; do
      err placeholder "$f:${hit%%:*} CODEOWNERS 负责人是占位符：$(clip "${hit#*:}")"
    done < <(grep -nE '@(OWNER|owner|your[-_A-Za-z]*|username|user|TODO|todo|xxx|org/team|example)([[:space:]]|$)|<[^>]+>' "$f" \
      | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done
}

check_ignored_rules() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then info "非 git 仓库，跳过 ignored-rules"; return 0; fi
  local p src
  for p in AGENTS.md .cursor/rules/x.mdc .cursor/hooks.json .agents/skills/x/SKILL.md .agents/deny-commands.txt \
    .agents/protected-ports .agents/hooks/guard-shell.sh .claude/settings.json scripts/gate.local.sh .paradigm/lock; do
    if git check-ignore -q --no-index "$p" 2>/dev/null; then
      src=$(git check-ignore -v --no-index "$p" | cut -f1)
      err ignored-rules "$p 会被忽略（$src），规则与门禁配置必须入库"
    fi
  done
}

fm_keys() { # 输出 frontmatter 中的 key=value
  awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
       /^---[[:space:]]*$/ { exit }
       { k = $0; sub(/:.*/, "", k); if (k ~ /^[A-Za-z_-]+$/) { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); print k "=" v } }' "$1"
}

check_frontmatter() {
  local f keys
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    keys=$(fm_keys "$f")
    if [ -z "$keys" ]; then err frontmatter "$f 缺少 YAML frontmatter（description + alwaysApply 或 globs）"; continue; fi
    grep -qE '^description=.+' <<< "$keys" || err frontmatter "$f 的 frontmatter 缺少 description"
    grep -qE '^(alwaysApply|globs)=' <<< "$keys" || err frontmatter "$f 的 frontmatter 缺少 alwaysApply 或 globs"
  done < <(aep_files | grep -E '^\.cursor/rules/.+\.mdc$' || true)
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    keys=$(fm_keys "$f")
    if ! grep -qE '^name=.+' <<< "$keys" || ! grep -qE '^description=.+' <<< "$keys"; then
      err frontmatter "$f 的 frontmatter 缺少 name 或 description"
    fi
  done < <(aep_files | grep -E '^\.agents/skills/[^/]+/SKILL\.md$' || true)
}

check_agents_budget() {
  local max sub f n
  max=$(aep_conf agents_max_lines 80)
  sub=$(aep_conf agents_sub_max_lines 30)
  if [ -f AGENTS.md ]; then
    n=$(wc -l < AGENTS.md | tr -d ' ')
    [ "$n" -le "$max" ] || err agents-budget "AGENTS.md 有 $n 行，超出预算 $max 行（解释性内容移到 docs/）"
  else
    warn agents-budget "缺少 AGENTS.md"
  fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" | tr -d ' ')
    [ "$n" -le "$sub" ] || err agents-budget "$f 有 $n 行，子目录 AGENTS.md 预算 $sub 行"
  done < <(aep_files | grep -E '^.+/AGENTS\.md$' || true)
}

check_redline_map() {
  [ -f AGENTS.md ] || return 0
  local table id rule enf chk prof note c n line ids rank_cur
  table=$(mktemp)
  # shellcheck disable=SC2046
  parse_enforcement $(enforcement_files) > "$table"
  if [ ! -s "$table" ]; then rm -f "$table"; warn redline-map "没有 .agents/enforcement.yaml，无法核对红线的执行点"; return 0; fi
  while IFS="$FS" read -r n line; do
    ids=$(grep -oE 'R:[a-z0-9-]+' <<< "$line" | sed 's/^R://' || true)
    if [ -z "$ids" ]; then
      err redline-map "AGENTS.md:$n 红线没有登记执行点（行尾加 <!-- R:<id> -->，并在 .agents/enforcement*.yaml 登记；没有机器执行点就登记为 advisory）"
      continue
    fi
    for id in $ids; do
      awk -F "$FS" -v id="$id" '$1 == id { f = 1 } END { exit !f }' "$table" \
        || err redline-map "AGENTS.md:$n 引用的 R:$id 不在 .agents/enforcement*.yaml 中"
    done
  done < <(awk -v fs="$FS" '/^#+[[:space:]]/ { sec = ($0 ~ /红线/); next } sec && /^[[:space:]]*[-*][[:space:]]/ { print NR fs $0 }' AGENTS.md)
  rank_cur=$(aep_rank "$(aep_profile)")
  while IFS="$FS" read -r id rule enf chk prof note; do
    [ "$(aep_rank "${prof:-spike}")" -le "$rank_cur" ] || continue
    case "$enf" in
      hook|gate|lint|ci) ;;
      advisory) continue ;;
      *) err redline-map "enforcement：$id 的 enforce 只能是 hook / gate / lint / ci / advisory（当前：${enf:-空}）"; continue ;;
    esac
    if [ -z "$chk" ]; then err redline-map "enforcement：$id 没有填写 check（执行点）"; continue; fi
    for c in $chk; do
      [ ! -e "$c" ] || continue
      if aep_excluded "$c"; then
        warn redline-map "$id 的执行点 $c 被 .paradigm/excludes 排除：在项目自己的 CI / hook 中等价实现，并登记到 .agents/enforcement.project.yaml"
      else
        err redline-map "$id 的执行点不存在：$c"
      fi
    done
  done < "$table"
  rm -f "$table"
}

check_acceptance() {
  if [ ! -x scripts/check-acceptance.sh ] || [ ! -d acceptance ]; then return 0; fi
  local out rc=0
  out=$(ACC_EVAL_MODE=warn scripts/check-acceptance.sh 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^ */  /'
  [ "$rc" = 0 ] || err acceptance "验收条目缺少对应的测试或 eval（见上）"
}

check_task_cards() { # 模板（_ 开头）只校验 schema；正式卡片还要求引用的 AC 存在
  [ -x scripts/render-task-card.sh ] || return 0
  local f out line opt
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    opt=--strict
    case "$(basename "$f")" in _*) opt="" ;; esac
    # shellcheck disable=SC2086
    if out=$(scripts/render-task-card.sh "$f" --check $opt 2>&1); then
      [ -n "$opt" ] || continue
      while IFS= read -r line; do
        case "$line" in *'⚠ '*) warn task-cards "${line#*⚠ }" ;; esac
      done <<< "$out"
    else
      err task-cards "$f 校验失败（scripts/render-task-card.sh $f --check${opt:+ $opt}）："
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
  done < <(aep_files | grep -E '^docs/progress/cards/[^/]+\.(ya?ml|json)$' || true)
}

check_misc() {
  if [ -f CLAUDE.md ] && [ ! -L CLAUDE.md ] && [ -f AGENTS.md ] && ! cmp -s CLAUDE.md AGENTS.md; then
    warn claude-link "CLAUDE.md 是独立文件且与 AGENTS.md 不同：改为 symlink（ln -sf AGENTS.md CLAUDE.md），保持单一真源"
  fi
  local d name
  if [ -f .agents/skills/manifest.toml ]; then
    for d in .agents/skills/*/; do
      [ -f "${d}SKILL.md" ] || continue
      name=$(basename "$d")
      grep -qE "^name[[:space:]]*=[[:space:]]*\"$name\"" .agents/skills/manifest.toml \
        || warn skills-registry ".agents/skills/$name 没有在 manifest.toml 登记"
    done
  fi
  if [ -f .paradigm/lock ]; then
    local mod=0 miss=0 h p
    while read -r _ h p; do
      if [ ! -e "$p" ]; then miss=$((miss + 1)); elif [ "$(aep_sha256 < "$p")" != "$h" ]; then mod=$((mod + 1)); fi
    done < <(awk '$1 == "inherit"' .paradigm/lock)
    info "范式 v$(awk '$1 == "version" { print $2 }' .paradigm/lock)（$(aep_profile)）：继承层本地修改 $mod 个、缺失 $miss 个"
  fi
}

case "${1:-}" in
  --render) shift; render "$@"; exit $? ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --only) ONLY=${2:?}; shift 2 ;;
    *) echo "用法：$0 [--strict] [--only <检查 id>] | --render [yaml…]" >&2; exit 2 ;;
  esac
done

want deny-cmd && check_deny_cmd
want ci-advisory && check_ci_advisory
want placeholder && check_placeholder
want ignored-rules && check_ignored_rules
want frontmatter && check_frontmatter
want agents-budget && check_agents_budget
want redline-map && check_redline_map
want acceptance && check_acceptance
want task-cards && check_task_cards
[ -n "$ONLY" ] || check_misc

if [ "$ERRORS" -gt 0 ]; then echo "  rule-doctor：$ERRORS 项错误，$WARNS 项警告"; exit 1; fi
if [ "$STRICT" = 1 ] && [ "$WARNS" -gt 0 ]; then echo "  rule-doctor：$WARNS 项警告（--strict）"; exit 1; fi
echo "  rule-doctor：通过（$WARNS 项警告）"
