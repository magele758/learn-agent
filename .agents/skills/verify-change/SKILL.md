---
name: verify-change
description: 在声称改动完成、提 PR、或把任务卡标为 done 之前使用。按 AC 跑分档门禁，产出可粘贴的验证证据。
version: 0.1.0
---

# verify-change

## 步骤

1. 找到本次改动关联的 `acceptance/<id>.yaml` 与 AC 列表（任务卡或 PR 中引用）。
2. 确认每条 AC 至少有一个标题带 `[AC:<id>#AC-n]` 的测试：`scripts/check-acceptance.sh`。
3. 运行 `scripts/gate.sh merge`（UI 改动另跑相关 e2e 并保存截图到 `artifacts/`）。
4. 产出证据块，粘贴到 PR 描述 / 任务卡：

```
验证：
- 命令：scripts/gate.sh merge → 通过（耗时 Xm）
- AC 覆盖：<id> AC-1..AC-n 全部有通过测试
- e2e / 截图：artifacts/<file>（如适用）
- 未验证：<项> —— 原因：<…>；人工步骤：<…>
- 剩余风险：<…>
```

## 验收清单

- [ ] 没有为通过门禁而 skip / mock / 放宽断言
- [ ] 证据是实际运行输出，不是推测
- [ ] 未验证项已明确列出
