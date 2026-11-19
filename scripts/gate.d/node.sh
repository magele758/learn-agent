# 技术栈适配：Node。包管理器按锁文件识别（pnpm-lock.yaml / yarn.lock / bun.lock(b) / package-lock.json）。
# 由 scripts/gate.sh source；函数在各 Node 项目目录内执行。

node_detect() { manifest_dirs package.json; }

node_pm() {
  local d=$PWD
  while :; do
    if [ -f "$d/pnpm-lock.yaml" ]; then echo pnpm; return 0; fi
    if [ -f "$d/yarn.lock" ]; then echo yarn; return 0; fi
    if [ -f "$d/bun.lockb" ] || [ -f "$d/bun.lock" ]; then echo bun; return 0; fi
    if [ -f "$d/package-lock.json" ]; then echo npm; return 0; fi
    if [ "$d" = "$GATE_ROOT" ] || [ "$d" = / ]; then break; fi
    d=$(dirname "$d")
  done
  echo npm
}

node_pm_exec() {
  local pm
  pm=$(node_pm)
  if command -v "$pm" >/dev/null 2>&1; then "$pm" "$@"
  elif command -v corepack >/dev/null 2>&1; then corepack "$pm" "$@"
  elif command -v npx >/dev/null 2>&1; then npx --yes "$pm" "$@"
  else echo "  ✗ 未找到包管理器 $pm" >&2; return 1
  fi
}

node_has_script() {
  node -e 'const s = require("./package.json").scripts || {}; process.exit(s[process.argv[1]] ? 0 : 1)' "$1"
}

node_has_deps() {
  node -e 'const p = require("./package.json"); const n = Object.keys({ ...p.dependencies, ...p.devDependencies, ...p.optionalDependencies }).length; process.exit(n ? 0 : 1)'
}

node_install() {
  [ ! -d node_modules ] || return 0
  node_has_deps || return 0
  local pm
  pm=$(node_pm)
  echo "  \$ $pm install"
  case "$pm" in
    pnpm|bun) node_pm_exec install --frozen-lockfile ;;
    yarn)
      case "$(node_pm_exec --version)" in
        1.*) node_pm_exec install --frozen-lockfile ;;
        *) node_pm_exec install --immutable ;;
      esac ;;
    *) if [ -f package-lock.json ]; then npm ci; else npm install; fi ;;
  esac
}

node_run() { # 依次尝试脚本名，运行第一个存在的
  local s
  for s in "$@"; do
    if node_has_script "$s"; then
      echo "  \$ $(node_pm) run $s"
      node_pm_exec run "$s"
      return
    fi
  done
  echo "  · package.json 没有脚本 $*（跳过）"
}

node_lint()        { node_install; node_run lint; node_run typecheck type-check; }
node_unit()        { node_install; node_run test:unit test; }
node_integration() { node_install; node_run test:integration; }
node_e2e()         { node_install; node_run test:e2e e2e; }
node_slow()        { node_install; node_run test:full test:slow; }
