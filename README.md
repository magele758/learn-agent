# learn-agent

学习向 Agent 的本地草案。先把理解测清楚，再按依赖教一个推理步骤，然后练习，并把命题留在本地。

- 调研：`docs/research.md`
- PRD：`docs/PRD.md`
- 功能列表：`docs/FEATURES.md`
- 分工：`docs/WORKSTREAMS.md`

运行时循环用本机 `ppeng-agent-core/packages/agent-loop`（包名 `@ppeng/agent-loop`，说明里也写作 `@mage-ai-lab/agent-loop`）。学习领域的代码在本目录，不复制 LearnHarness 的源码。

许可证还没定。在定下来之前，不要把 AGPL 项目的源码抄进这里。

## 开发

- 验证：`scripts/gate.sh fast`（类型检查和 `npm test`）
- 已有文档仍在：`docs/PRD.md`、`docs/FEATURES.md`、`docs/WORKSTREAMS.md`、`docs/research.md`
- 类型检查需要上一级目录中的 `ppeng-agent-core`。没有它时，门禁只跑不加载该包的命题检查，并跳过 tsc。
