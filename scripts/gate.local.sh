# 项目门禁（自有层）。技术栈 Node(npm)。
# 命题闭环不调用模型：npm test = node --experimental-strip-types src/cli/check.ts
# 类型检查会解析 file:../ppeng-agent-core/packages/agent-loop。旁边没有这份仓库时不改去安装同名包。

install_deps() {
  if [ -d node_modules ]; then return 0; fi
  if [ ! -f ../ppeng-agent-core/packages/agent-loop/package.json ]; then
    return 1
  fi
  echo "  \$ npm ci --ignore-scripts"
  npm ci --ignore-scripts
}

run_lint() {
  if install_deps; then
    echo "  \$ npm run typecheck"
    npm run typecheck
    return
  fi
  echo "  · 这台机器没有仓库外的 agent-loop，跳过 tsc"
  node --experimental-strip-types --check src/cli/check.ts
  node --experimental-strip-types --check src/session/runner.ts
  node --experimental-strip-types --check src/session/agent-loop.ts
}

run_unit() {
  if install_deps; then
    echo "  \$ npm test"
    npm test
    return
  fi
  echo "  · 无仓库外依赖，直接跑不加载该包的检查"
  node --experimental-strip-types src/cli/check.ts
}
