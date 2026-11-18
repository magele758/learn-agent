# 调研

日期：2026-11-10。只记实际读到的材料。没有克隆 LearnHarness，也没有把它的源码抄进来。

## LearnHarness

- 仓库：https://github.com/amosblomqvist/learnharness
- 主页：https://learnharness.ai
- GitHub API（2026-11-10）：语言 TypeScript，许可证 AGPL-3.0，默认分支 main，星标 7795，最近推送 2026-11-09。描述是 “Agent harness for learning difficult things”。
- README 的产品定义：不是聊天机器人，是学习 harness。循环是 measure → plan → teach → practice。一次只教一个推理步骤，要求把推理说出来，而不是先给结论。
- 理解的记录方式：知识图谱。节点是命题，边是依赖和推理链。不是给能力打一个分。
- 运行形态：桌面应用（Tauri）和网页。自带模型，数据在本地。有可视化讲解。
- 文档目录里还有：architecture、teaching-methodology、custom-providers、compaction-accounting、desktop-release。这次读了 README 和文档文件名，没有通读 architecture 全文。
- 许可证限制：AGPL-3.0。本项目只吸收做法，不复制、不改编它的源码。

可以留下的做法：

1. 先测量，再排依赖，再教，再练。
2. 一次一个推理步骤，并要求说出来。
3. 用命题和依赖记录理解，不用单一分数。
4. 模型可替换，学习记录留在本地。

不照搬的部分：桌面安装包、它的界面、它的 AGPL 源码。

## 本机 agent-loop

- 路径：上一级目录的 `ppeng-agent-core/packages/agent-loop`（与 `package.json` 的 `file:` 依赖一致）。
- `package.json` 的包名是 `@ppeng/agent-loop`。README 标题写作 `@mage-ai-lab/agent-loop`。
- README：可嵌入的 Agent 循环。`createAssembledLoop({ preset })` 组装循环，`createHandle(sessionId)` 只在 `full` 和 `max` 上提供，然后 `run()` 一轮、`fold()` 取折叠后的消息。
- Bot 模式不在这个包里。本项目只用它做模型回合、工具执行和停止条件。学习阶段机是本目录自己的代码。

## 同类项目

GitHub 搜索 `learning agent tutor harness`（按星标，2026-11-10）里，和「专门辅助学习」更接近的是：

| 项目 | 实际看到的描述 | 可取之处 | 不取之处 |
| --- | --- | --- | --- |
| TecFancy/dsh-deeptutor | DeepSeek harness 插件，个人深度导师：深讲、自测、学习路径、RAG、笔记归档。语言 TypeScript，星标 3。 | 学习路径、自测、笔记可检索 | 它绑在 DeepSeek harness 插件上，不是我们的运行时 |
| dungnotnull/AI-Machine-Learning-Deep-Learning-Tutor-agent-skill | 仓库描述写了 BKT、间隔检索、苏格拉底式提问、认知负荷管理。星标 1。只看了描述，没有读实现。 | 间隔复习和一次只加一个概念 | 不把它的掌握度公式当成已验证算法 |
| ketiyohannes/mint | 描述是 AI 导师和自习桌面应用，Electron，许可证 MIT，星标 0。 | 自习、MIT、本地应用这个形状 | 没有看到可复用的学习记录模型 |

科研小助手 2026-11-09 的 20 个开源仓库里有 `google-research/harness2` 和 `deepseek-ai/dsh-superagent-prototype`。那份名单不是学习产品方案，这次不把它们写成功能来源。

## 取舍

第一版做成命令行里的一个学习会话：测量、计划、单步教学、练习、本地命题图。界面、桌面壳、间隔调度留到图和会话能跑之后。
