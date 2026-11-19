# AGENTS.md — learn-agent

> 只写红线和“会静默出错”的事实，≤ 80 行。解释性内容放 `docs/`。子目录 AGENTS.md 只写模块局部事实。

## 0. 入口

- 先读 `docs/feature-map.md` 定位：用户入口 → 实现 → 验证。
- 需求真源：`acceptance/*.yaml`；计划：`docs/plans/`；工程约束唯一出处：`docs/engineering-constraints.md`。
- 唯一验证入口：`scripts/gate.sh fast|merge|full`；项目定制只写在 `scripts/gate.local.sh`。
- `.paradigm/lock` 登记的继承层文件随 `paradigm upgrade` 更新（本地修改会三方合并保留）；项目专属内容写自有层文件。

## 1. 工作方式

- 验收先行：行为变更先有 `approved` 的 acceptance；写完验收当轮实现，不停下等批准（标记 `needs-human` 的除外）。
- 完成 = `scripts/gate.sh merge` 通过 + 命令与结果写进 PR / 任务卡；没验证就写“未验证 + 原因”。
- 同一切片 3 次门禁失败 → 停下写交接说明（`docs/handoff/` 或任务卡），不继续堆补丁。

## 2. 红线

- 不修改用户确认的契约断言；不用 skip / only / mock / 删断言把红灯变绿。<!-- R:no-weaken-assertions -->
- 不 force push、不 `--no-verify`、不 `reset --hard` / `stash` / `checkout --` 他人改动。<!-- R:no-force-push R:no-verify-bypass R:no-destructive-git -->
- 不对共享运行实例做 stop / rebuild / kill（见 §4）。<!-- R:no-touch-main-stack R:no-kill-protected-ports -->
- 不提交密钥、`.env*`、会话日志、大二进制、主机名 / IP / 个人绝对路径；配置里只引用环境变量。<!-- R:no-secrets R:no-session-logs R:no-large-binaries R:no-private-info -->
- 安全扫描拦住就改内容（环境变量 / 占位符 / 明显的假值），不把真值登记进 allowlist；公开仓库不放公司私有代码的分析。<!-- R:prepush-scan R:allowlist-fake-only R:no-private-analysis-in-public -->
- 缺身份 / 配置直接报错，不填默认值。<!-- R:fail-fast-config -->

## 3. 提交与 PR

- Conventional Commits：`type(scope): 用户视角一句话`；禁止把对话回复原文当标题。
- 对用户可见的改动加 trailer `Release-Note: …`；改已批准 AC 加 `Contract-Change: …`；关联任务加 `Task: …`。
- 分支：`<executor>/<card-id>-<slug>`（executor：cursor / codex / claude / vk / human）。
- 每个 clone（含远端 / 云端 agent 的 clone；worktree 共享）启用一次 hooks：`git config core.hooksPath scripts/git`；agent 推送的分支同样经过 pre-push。

## 4. 运行实例与隔离

- 主实例端口登记在 `.agents/protected-ports`，主实例的停止 / 重建命令登记在 `.agents/deny-commands.project.txt`；agent 一律不得触碰。
- agent 只在自己的 worktree 中运行隔离实例，端口用 `eval "$(scripts/dev-ports.sh --env)"` 分配（按分支确定，避开受保护端口）。
- 文档中任何“重启 / 重建主实例”的说明均 **仅限人工在主仓执行**。

## 5. 改动联动

| 改了 | 必须同步 |
|---|---|
| 用户入口 / 交互契约 | `docs/feature-map.md` 对应行 |
| 对外接口 / 数据结构 | schema、`docs/`、相关 skill |
| prompt / skill | bump 其 `version` |
| 已批准的 AC | `Contract-Change:` trailer + 通知负责人 |
| prompt（`prompts/`）/ 模型版本 | 版本标记 + `scripts/eval-compare.sh --run` 对比通过；模型变更记 `docs/models.md` |

## 6. 工作区事实（会静默出错）

- 语言 / 包管理：Node(npm)。`npm test` 跑 `src/cli/check.ts`；`npm run typecheck` 跑 tsc。门禁见 `scripts/gate.local.sh`。
- `@ppeng/agent-loop` 只来自上一级目录的 `file:` 依赖。旁边没有时安装失败，不会改去下载同名包。
- `loadAgentLoop()` 在包缺失时返回 `{ ok: false }`，不抛错。只判断“没抛异常”会把模型当成可用。
- `src/reading/ask.ts` 在文件顶层 import 这个包。包不在时是模块加载失败，不是上面的 `{ ok: false }`。
- 命题状态只有 `unknown`、`learning`、`stable`。前置必须写成依赖边；没有前置时留空，不要靠缺字段表示。
- 图谱在 `data/graph.json`。`npm test` 会改写它。没有网络副本。
- 阅读命令默认端口 4173。不传 `--port` 时，第二次启动会撞上第一次。
- 许可证未定。不要把 AGPL 的 LearnHarness 源码抄进本仓库。
- 不修改旁边 `ppeng-agent-core` 里正在运行的服务。门禁用 `npm ci --ignore-scripts`，避免跑它的生命周期脚本。
