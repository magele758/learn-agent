# 产品功能地图

从现有 README、`docs/FEATURES.md` 和已提交代码提炼。成本、延迟、使用信号文档里没有写，标成待确认，没有替你填数。

| 用户入口 | 用户可观察的行为 | 从哪里改 | 从哪里验证 | AC | 成本预算 | 延迟预算 | 使用信号 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `npm test` 演示闭环 | 测量、计划、教学、练习后，prior 为 stable，claim 仍为 unknown，图谱写在 `data/graph.json` | `src/cli/run.ts`、`src/session/runner.ts` | `src/cli/check.ts` | local-loop | 不涉及 | 不涉及 | 待确认 |
| `read --doc` | 在本机打开已导入的 PDF。默认端口 4173，可用 `--port` 改 | `src/cli/reading.ts`、`src/reading/server.ts` | `src/cli/reading.check.ts` | 待确认 | 不涉及 | 待确认 | 待确认 |
| 划线提问 | 把选中文字交给 `@ppeng/agent-loop`。本仓库不选模型 | `src/reading/ask.ts` | `src/reading/ask.check.ts` | 待确认 | 待确认 | 待确认 | 待确认 |

提炼来源：README 的四步循环；FEATURES 的 P0（F1–F11）和「明确不做」。

待确认（文档没有定，或代码已经做了但 FEATURES 还放在后面）：

- 划线提问算不算第一版。FEATURES 的 P0 没有单独列阅读器，代码里已经有。
- 模型由谁配置、预算是多少。本仓库只引用旁边的 `ppeng-agent-core`。
- 怎么知道有人在用。没有埋点说明。
