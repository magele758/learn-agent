#!/usr/bin/env bash
# 给当前分支（默认）或 worktree 确定性地分配一段 agent 端口：eval "$(scripts/dev-ports.sh --env)"
# 在 .agents/paradigm.conf 的 dev_ports_range 内按 key 的 hash 取一段 dev_ports_block 个端口；
# 与 .agents/protected-ports 有交集就确定性地顺延到下一段。占用检查只读，从不结束任何进程。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/aep.sh

usage() {
  cat <<'EOF'
用法：scripts/dev-ports.sh [--key <key> | --by branch|path] [--names web,api,…] [--env] [--no-check]
                           [--range A-B] [--block N]
  key         默认当前分支名；--by path 用 worktree 根目录的绝对路径；--key 直接指定（任务卡传分支名）
  --names     具名端口，按顺序取段内端口，导出为 PORT_WEB、PORT_API …
  --env       输出可 eval 的 export（PORT_BASE PORT_END PORT PORT_<NAME> DEV_PORTS_KEY），提示写到 stderr
  --no-check  不检查段内端口是否已被监听（默认用 lsof / ss 只读检查）
  区间 / 段大小默认取 .agents/paradigm.conf 的 dev_ports_range / dev_ports_block（AEP_DEV_PORTS_RANGE / AEP_DEV_PORTS_BLOCK 优先）
EOF
}
die() { echo "dev-ports：$*" >&2; exit 2; }
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
arg() { case "$1" in *[!A-Za-z0-9_./,:=@+-]*|'') shq "$1" ;; *) printf '%s' "$1" ;; esac; }

key="" by=branch names="" fmt=human check=1 range="" block="" again=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key|--by|--names|--range|--block)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 需要一个值"
      case "$1" in
        --key) key=$2 ;; --by) by=$2 ;; --names) names=$2 ;; --range) range=$2 ;; --block) block=$2 ;;
      esac
      again="$again $1 $(arg "$2")"; shift 2 ;;
    --env) fmt=env; shift ;;
    --no-check) check=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：$1" ;;
  esac
done

if [ -z "$key" ]; then
  case "$by" in
    branch)
      key=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
      [ -n "$key" ] || die "当前不在分支上（detached HEAD 或不是 git 仓库）：用 --key <名字> 或 --by path" ;;
    path) key=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P) ;;
    *) die "--by 只能是 branch 或 path" ;;
  esac
fi
range=${range:-$(aep_conf dev_ports_range 20000-29999)}
block=${block:-$(aep_conf dev_ports_block 10)}

out=$(perl scripts/lib/ports.pl alloc "$range" "$block" "$key" .agents/protected-ports) || exit 2
read -r base end skipped <<< "$out"

named="" seen=" " i=0
while IFS= read -r n; do
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  [ -n "$n" ] || continue
  case "$n" in [A-Za-z]*) ;; *) die "端口名要以字母开头：$n" ;; esac
  case "$n" in *[!A-Za-z0-9_]*) die "端口名只能含字母、数字、下划线：$n" ;; esac
  up=$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')
  case "$seen" in *" $up "*) die "端口名重复：$n" ;; esac
  [ "$i" -lt "$block" ] || die "具名端口比段大小 $block 还多"
  seen="$seen$up "
  named="${named}PORT_$up=$((base + i))
"
  i=$((i + 1))
done <<< "$(printf '%s' "$names" | tr ',' '\n')"

busy="" nocheck=""
if [ "$check" = 1 ]; then
  rc=0
  busy=$(perl scripts/lib/ports.pl listening "$base" "$end") || rc=$?
  [ "$rc" != 3 ] || nocheck="没有 lsof / ss，跳过占用检查"
fi
notes() {
  [ "$skipped" = 0 ] || echo "与受保护端口（.agents/protected-ports）重叠，已顺延 $skipped 段"
  [ -z "$nocheck" ] || echo "$nocheck"
  if [ -n "$busy" ]; then
    printf '%s\n' "$busy" | while read -r p pid name; do
      echo "端口 $p 已被 ${name:-?}（pid $pid）监听：只读提示，不要结束它；换 --key 或等它退出"
    done
  fi
  return 0
}

if [ "$fmt" = env ]; then
  printf 'export PORT_BASE=%s\nexport PORT_END=%s\nexport PORT=%s\n' "$base" "$end" "$base"
  printf '%s' "$named" | sed 's/^/export /'
  printf 'export DEV_PORTS_KEY=%s\n' "$(shq "$key")"
  notes | sed 's/^/dev-ports：⚠ /' >&2
else
  echo "dev-ports：$base-$end（key：$key）"
  echo "  区间 $range，每段 $block 个；PORT=$base$(printf '%s' "$named" | tr '\n' ' ' | sed 's/^/  /; s/ $//')"
  notes | sed 's/^/  ⚠ /'
  echo "  在 shell 中使用：eval \"\$(scripts/dev-ports.sh --env$again)\""
fi
