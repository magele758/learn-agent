#!/usr/bin/env bash
# Agent shell 命令守卫：Cursor beforeShellExecution 与 Claude Code PreToolUse(Bash) 共用同一份规则。
# 禁令（每行一个 ERE）：.agents/deny-commands.txt（范式）、.agents/deny-commands.project.txt（项目）、
#   $AEP_CONFIG_DIR/deny-commands.txt（个人，仓库外；默认 ~/.config/ai-eng-paradigm）。
# 受保护端口：.agents/protected-ports 中的端口，kill / pkill / killall / lsof | kill / fuser -k / kill-port 一律拦截
#   （scripts/lib/ports.pl guard；kill <pid> 与 pkill 会只读地查目标进程是否在监听这些端口）。
set -u
input=$(cat)
cmd=$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
[ -n "$cmd" ] || cmd=$input
case "$input" in *'"tool_input"'*) client=claude ;; *) client=cursor ;; esac
cd "$(dirname "$0")/../.." || exit 0

deny() {
  if [ "$client" = claude ]; then
    printf '命令被项目守卫拦截：%s。不要绕过；确有必要请向用户说明，由用户手动执行。\n' "$1" >&2
    exit 2
  fi
  local safe
  safe=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"permission":"deny","user_message":"命令被项目守卫拦截：%s","agent_message":"命中守卫规则（%s）。不要绕过；如确有必要，请向用户说明并由用户手动执行。"}\n' "$safe" "$safe"
  exit 0
}

personal=${AEP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ai-eng-paradigm}/deny-commands.txt
for list in .agents/deny-commands.txt .agents/deny-commands.project.txt "$personal"; do
  [ -f "$list" ] || continue
  label=$list; [ "$list" != "$personal" ] || label=个人禁令
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue ;; esac
    if grep -Eq -- "$pattern" <<< "$cmd"; then deny "$pattern（$label）"; fi
  done < "$list"
done

if [ -f .agents/protected-ports ] && [ -f scripts/lib/ports.pl ] && grep -Eq 'kill|fuser|docker|(^|[^[:alnum:]])ss ' <<< "$cmd"; then
  rc=0
  hit=$(printf '%s' "$input" | perl scripts/lib/ports.pl guard .agents/protected-ports) || rc=$?
  if [ "$rc" = 1 ]; then deny "$hit（.agents/protected-ports）"; fi
fi

[ "$client" = claude ] || echo '{"permission":"allow"}'
exit 0
