# 安全检查共享函数，被 source；调用方须先 cd 到仓库根目录并 source 同目录的 aep.sh。
# 私有模式：$(aep_config_dir)/private-patterns.txt（仓库外，每行一个 ERE，大小写不敏感），列出不便写进仓库的主机名等。
# 项目豁免：.agents/security-allowlist（每行一个 ERE，匹配 “路径:内容” 即放行；只用于明显的假值）。

SEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# credentials 只拦数据 / 配置类扩展名：credentials.ts 这类源码文件不算
SEC_BAD_NAMES='(^|/)\.env($|\.)|(^|/)credentials(\.(json|toml|ya?ml|ini|cfg|conf|env|txt|xml|properties|csv|db|sqlite|plist|bak))?$|(^|/)secrets?\.(env|ya?ml|json|toml)$|\.(pem|p12|pfx|key|keystore|jks)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)sessions?/(.*/)?[^/]*\.jsonl$|(^|/)(\.pi|\.omp|\.codex)/.*\.jsonl$|(^|/)\.claude/projects/|(^|/)agent-transcripts?/|(^|/)(Cookies|Cookies-journal|Login Data|Login Data-journal|Web Data|Local State|cookies\.sqlite|key[34]\.db|Cookies\.binarycookies)$|(^|/)\.DS_Store$|\.paradigm-new$'
SEC_NAME_OK='(^|/)[^/]*\.(example|sample|template)(\.[A-Za-z0-9]+)?$'
SEC_PREFILTER='BEGIN [A-Z ]*PRIVATE|AKIA|ASIA|gh[pousr]_|github_pat_|sk-|xox[abprs]-|AIza|eyJ|api.?key|secret|token|passw|private.?key|/Users/|/home/|ts\.net|100\.'

sec_env() {
  export AEP_PRIVATE_PATTERNS=${AEP_PRIVATE_PATTERNS:-$(aep_config_dir)/private-patterns.txt}
  export AEP_SECURITY_ALLOWLIST=${AEP_SECURITY_ALLOWLIST:-$PWD/.agents/security-allowlist}
  AEP_MAX_SUBJECT=${AEP_MAX_SUBJECT:-$(aep_conf max_subject_chars 100)}
  export AEP_MAX_SUBJECT
}

sec_has_gitleaks() { [ "${AEP_NO_GITLEAKS:-0}" != 1 ] && command -v gitleaks >/dev/null 2>&1; }
sec_gitleaks_hint() { echo "  · 未安装 gitleaks，密钥改用内置正则兜底（建议安装：brew install gitleaks）"; }

sec_scan() { perl "$SEC_DIR/secscan.pl" "$@"; }

sec_bad_names() { grep -E "$SEC_BAD_NAMES" | grep -vE "$SEC_NAME_OK" || true; }

sec_clean_message() { awk '/^# -+ >8 -+$/ { exit } !/^#/'; }

sec_private_args() { # 私有模式文件里合法的 ERE，作为 git grep 的 -e 参数逐行输出
  local p rc
  [ -f "$AEP_PRIVATE_PATTERNS" ] || return 0
  while IFS= read -r p || [ -n "$p" ]; do
    case "$p" in ''|'#'*) continue ;; esac
    rc=0; grep -Eq -- "$p" < /dev/null 2>/dev/null || rc=$?
    if [ "$rc" = 2 ]; then echo "  ⚠ 私有模式不是合法 ERE，已跳过：private-patterns.txt 中的一行" >&2; continue; fi
    printf '%s\n' "$p"
  done < "$AEP_PRIVATE_PATTERNS"
}

sec_grep_tree() { # [git grep 参数…]：工作区中可能命中的行（宽松预过滤，交给 secscan.pl 精确判断）
  local args=(-e "$SEC_PREFILTER") p
  while IFS= read -r p; do args+=(-e "$p"); done < <(sec_private_args)
  git grep "$@" -nIiE "${args[@]}" || true
}

sec_big_files() { # stdin：“<blob sha> <说明>”；--paths 时 stdin 为工作区路径。输出超过上限的文件与大小
  local max
  max=$(( $(aep_conf max_file_kb 5120) * 1024 ))
  if [ "${1:-}" = --paths ]; then
    perl -nle 'my $s = -s $_; printf "      %s（%d KB）\n", $_, $s / 1024 if defined $s && $s > '"$max"
  else
    git cat-file --batch-check='%(objectsize) %(rest)' \
      | awk -v max="$max" '$1 ~ /^[0-9]+$/ && $1 > max { r = $0; sub(/^[0-9]+ /, "", r); printf "      %s（%d KB）\n", r, $1 / 1024 }'
  fi
}
