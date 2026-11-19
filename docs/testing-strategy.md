# 测试策略

| 层 | 内容 | 档位 | 命令 | 证据 |
|---|---|---|---|---|
| L1 静态 | lint / typecheck / 依赖审计 / 产物漂移 | fast | `scripts/gate.sh fast` | CI 日志 |
| L2 单元 & 契约 | 单测；契约测试（受保护） | fast | | JUnit |
| L3 集成 | 真实依赖，隔离数据目录/端口 | merge | | JUnit + 日志 |
| L4 e2e | 关键用户路径；失败存截图与 trace | merge / nightly | | artifacts/ |
| L5 真实服务 / eval | live e2e、agent 质量评测（`evals/` 数据集 + 基线对比） | full；改 prompt 时 merge | `scripts/eval-compare.sh --run` | artifacts/evals/、docs/verification/ |

## 契约测试

用户确认过的行为放在 `<contract-test-path>`，修改断言必须带 `Contract-Change:` trailer 并经人确认。

## 已知 flaky（quarantine）

| 测试 | 卡号 | 截止日期 |
|---|---|---|
