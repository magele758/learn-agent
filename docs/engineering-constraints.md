# 工程约束（唯一出处）

从已提交代码提炼。没有 retro 的条目来源写代码路径。

## `src/session/runner.ts`

- 规则：命题状态只写成 `unknown`、`learning`、`stable`。练习通过才是 `stable`，否则回到 `learning`。
  - 违反后果：`plan` 用 `status !== "stable"` 判断前置，别的字符串会被当成还没学会，计划停在错误的命题上。
  - 来源：`src/session/runner.ts`，FEATURES 的 F1。
- 规则：未知命题 id 要抛 `missing proposition`。
  - 违反后果：调用方会把“没有这条命题”当成练习已写入。
  - 来源：`src/session/runner.ts`。

## `src/session/agent-loop.ts`

- 规则：找不到 `@ppeng/agent-loop` 时 `loadAgentLoop()` 返回 `{ ok: false }`，不要改成吞掉错误并返回成功。
  - 违反后果：阅读提问会在没有模型的情况下继续。
  - 来源：`src/session/agent-loop.ts`。

## `package.json`

- 规则：`@ppeng/agent-loop` 保持 `file:` 指向旁边仓库。不要改成注册表上的同名包。
  - 违反后果：装到另一份实现，类型和运行时对不上，而且门禁不再失败。
  - 来源：`package.json`。
