# 分工

三个任务只改自己的目录。不要改 `docs/`、`package.json`、`tsconfig.json`，不要改 `ppeng-agent-core`。

| 终端名 | 目录 | 对应功能 |
| --- | --- | --- |
| learn-graph | `src/graph/` | F1 F2 F3 F4 |
| learn-session | `src/session/` | F5 F6 F7 F8 F9 F10 |
| learn-cli | `src/cli/` | F11，只调用 session 和 graph 已导出的函数 |

图谱文件路径固定为 `data/graph.json`，由 graph 模块创建。会话模块不要另写一份存储。
