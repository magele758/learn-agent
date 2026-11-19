# evals：AI 行为评测

同一批用例 + 固定基线：改 prompt、换模型、调工具调用之后，用数字判断质量是否回退。范式继承文件；数据集与基线是自有层。

| 路径 | 层 | 说明 |
|---|---|---|
| `evals/datasets/<名称>.jsonl` | 自有 | 数据集；`_` 开头的是示例，不参与运行 |
| `evals/baseline.json` | 自有 | 基线，只用 `--update-baseline` 显式更新 |
| `artifacts/evals/latest.json` | 不入库 | 最近一次运行的合并结果（CI 失败时随 artifacts 上传） |
| `scripts/eval-run.sh` | 继承 | 零依赖的参考 runner |
| `scripts/eval-compare.sh` | 继承 | 跑 runner、与基线对比、更新基线 |
| `scripts/check-prompts.sh` | 继承 | prompt 改动门禁（`gate.sh merge`） |

## 数据集（JSONL，一行一条）

```json
{"id": "refund-1", "input": "我要退款，订单 A-1024", "expected": "refund", "criteria": "exact"}
```

| 字段 | 说明 |
|---|---|
| `id` | 数据集内唯一的字符串 |
| `input` | 给被测系统的输入：字符串或任意 JSON |
| `expected` | 期望：字符串或任意 JSON，含义由 `criteria` 决定 |
| `criteria` | 判定方式：字符串，或对象 `{"match": "…", …}`；对象的其他字段（如 `rubric`）留给项目自己的 runner |

## runner 约定

- 配置：`.agents/paradigm.conf` 的 `eval_runner=<命令>`，或在 `scripts/gate.local.sh` 中 `export AEP_EVAL_RUNNER=…`（环境变量优先）。没配置时 `gate.sh full` 提示跳过。
- 调用：每个数据集一次，在仓库根执行 `<命令> <数据集路径>`（路径相对仓库根，同时放在环境变量 `AEP_EVAL_DATASET`）。
- 输出：stdout 只写一个标准 JSON，日志写 stderr。产出了结果就退出 0（有用例失败也是 0），runner 自身出错才非 0。
- promptfoo、inspect 或自写脚本都可以，包一层把结果转成标准 JSON 即可；需要密钥时只从环境变量读。

### 标准 JSON

```json
{
  "pass_rate": 0.5,
  "cases": [
    {"id": "refund-1", "pass": true, "score": 1, "cost": 0.0012, "latency_ms": 840},
    {"id": "refund-2", "pass": false, "latency_ms": 1900, "error": "超时"}
  ],
  "cost": {"total": 0.0012, "unit": "USD"},
  "latency": {"p50_ms": 840, "p95_ms": 1900}
}
```

| 字段 | 说明 |
|---|---|
| `pass_rate` | 0–1 |
| `cases[]` | 每条必有 `id`、`pass`（true / false）；可选 `score`、`cost`、`latency_ms`、`error`；其他字段对比时忽略 |
| `cost` | `total`（≥ 0）与 `unit`；不计费写 0 |
| `latency` | `p50_ms`、`p95_ms`（毫秒） |

## 参考 runner：`scripts/eval-run.sh`

```bash
scripts/eval-run.sh --cmd 'node bin/answer.js' evals/datasets/refund.jsonl
scripts/eval-run.sh --cmd cat evals/datasets/_example.jsonl   # 示例：cat 原样回显，演示四种判定
```

- 每条用例的 `input` 写到被测命令的 stdin（字符串原样，其他 JSON 序列化），在仓库根用 `sh -c` 执行；stdout 去掉首尾空白后判定。环境变量 `AEP_EVAL_CASE_ID`、`AEP_EVAL_DATASET`。
- `criteria`：`exact`（全等）｜`contains`（包含 expected；列表须全部包含）｜`regex`（Perl 正则）｜`json`（stdout 解析为 JSON 后与 expected 结构相等）。
- 成本：被测命令在 stderr 输出一行 `AEP_EVAL_COST=<数值>` 即计入，单位 `--cost-unit`（默认 USD）。`--timeout <秒>`（默认 60）；超时、非 0 退出都算失败并写入 `error`。
- 语义相似、LLM 评分这类判定用项目自己的 runner。

## 对比与基线：`scripts/eval-compare.sh`

```bash
scripts/eval-compare.sh --run                    # 跑全部数据集 → artifacts/evals/latest.json → 与基线对比
scripts/eval-compare.sh --run --update-baseline  # 首次，或确认接受新结果：写入 evals/baseline.json，提交时写明原因
scripts/eval-compare.sh --current r.json         # 对比现成的结果（latest.json，或带 dataset 字段的单个标准 JSON）
```

阈值写在 `.agents/paradigm.conf`，`off` 表示不检查：

| 键 | 默认 | 超出时 |
|---|---|---|
| `eval_max_pass_rate_drop` | 0.05 | 通过率比基线低超过 5 个百分点：失败 |
| `eval_max_cost_increase` | 0.2 | 总成本比基线高超过 20%：按 `eval_on_budget` |
| `eval_max_p95_increase` | 0.5 | p95 比基线高超过 50% 且增量 ≥ 50 ms：按 `eval_on_budget` |
| `eval_max_cost` / `eval_max_p95_ms` | 空 | 绝对上限（单个数据集一次运行）：按 `eval_on_budget` |
| `eval_on_budget` | fail | `fail` 失败，`warn` 只告警 |

没有基线的数据集只报告、不判回退。基线通过、本次失败的用例会单独列出。

## 接入门禁

| 时机 | 做什么 |
|---|---|
| `scripts/gate.sh full`（nightly / 发布前） | 有 `evals/` 且配置了 runner：`eval-compare.sh --run`；否则提示跳过 |
| `scripts/gate.sh merge` | 相对 base 改了 prompt 文件：检查版本标记，要求 runner 已配置且对比通过（`check-prompts.sh`） |
| `--run` 之后 | `check-acceptance.sh` 按本次结果检查验收里 eval 引用的 `min_pass_rate` |

## prompt 文件

- 放在 `prompts/`（`paradigm.conf` 的 `prompt_dirs` 可改，空格分隔）；`README*` 与 `_`、`.` 开头的文件不算 prompt。
- 版本标记二选一：前 10 行写 `version: <N>`，改内容必须 bump；或文件名带 `.v<N>.`（如 `answer.v3.md`），base 中已有的版本不能原地改，复制为新版本再改引用，旧版本留作回滚。
- base：`GATE_BASE`（CI 设为 PR 的 base sha），否则取 `origin/HEAD`、`origin/main`、`main` 等与 HEAD 的 merge-base；都找不到时全部 prompt 视为改动。

## 验收引用 eval

```yaml
criteria:
  - id: AC-1
    given: 用户用自然语言描述退款诉求
    when: 意图识别
    then: 识别为 refund
    verify: eval
    eval: {dataset: evals/datasets/intent.jsonl, min_pass_rate: 0.9}
```

也可以写成块（`eval:` 下一行起缩进写 `dataset:`、`min_pass_rate:`），或简写 `eval: evals/datasets/intent.jsonl`（不设阈值）。引用了 eval 的 AC 由 eval 覆盖，不要求 `[AC:]` 测试标签；数据集缺失、格式不对或有未知字段时 `check-acceptance.sh` 失败。`min_pass_rate` 对照 `latest.json`：`eval-compare.sh --run` 之后与单独运行 `check-acceptance.sh` 时不达标即失败；结果不是当前提交生成的，或在 `gate.sh fast` 的 rule-doctor 里（结果可能早于工作区改动），只提示。
