# 范式脚本的共享函数，被 source；调用方须先 cd 到仓库根目录。

aep_conf() { # <key> [默认值]：环境变量 AEP_<KEY> 优先，其次 .agents/paradigm.conf
  local key=$1 def=${2-} env val
  env=AEP_$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')
  val=${!env-}
  if [ -z "$val" ] && [ -f .agents/paradigm.conf ]; then
    val=$(awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' .agents/paradigm.conf)
  fi
  printf '%s\n' "${val:-$def}"
}

aep_config_dir() { printf '%s\n' "${AEP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ai-eng-paradigm}"; }

aep_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

aep_profile() {
  local p=""
  if [ -f .paradigm/lock ]; then p=$(awk '$1 == "profile" { print $2; exit }' .paradigm/lock); fi
  printf '%s\n' "${p:-${AEP_PROFILE:-spike}}"
}

aep_rank() { case "$1" in spike) echo 1 ;; product) echo 2 ;; platform) echo 3 ;; *) echo 0 ;; esac; }

aep_excluded() { # <路径>：是否被 .paradigm/excludes 排除
  [ -f .paradigm/excludes ] || return 1
  local pat
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254
    case "$1" in $pat) return 0 ;; esac
  done < .paradigm/excludes
  return 1
}

aep_files() { # 仓库内文件列表（git 已跟踪 + 未被忽略的新文件；非 git 仓库时用 find）
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files -co --exclude-standard
  else
    find . -type f -not -path './.git/*' | sed 's|^\./||'
  fi
}
