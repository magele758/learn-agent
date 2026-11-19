## 做了什么（用户视角一句话）

## 验收

- 关联：`acceptance/<id>.yaml` AC-…　任务卡：…
- [ ] 每条相关 AC 都有带 `[AC:<id>#AC-n]` 标签且通过的测试
- [ ] 未修改用户确认的契约断言（如修改：已加 `Contract-Change:` trailer 并经确认）

## 验证证据（实际运行输出摘要）

```
scripts/gate.sh merge → 
```

- 截图 / e2e：
- 未验证项及原因：

## 风险与回滚

## 联动检查

- [ ] `docs/feature-map.md` 已更新（入口 / 契约有变时）
- [ ] 改了 prompt / 模型 / 数据集：贴 `scripts/eval-compare.sh --run` 结果；基线有变化时写明原因，模型变更已记 `docs/models.md`
- [ ] 用户可见改动的 commit 带 `Release-Note:` trailer
- [ ] 实现者 ≠ 复审者
