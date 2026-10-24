<p align="center"><img src="assets/logo-256.png" width="128" alt="Agentrise logo"></p>

<h1 align="center">Agentrise</h1>

一栋放在 Mac 桌面上的小写字楼：每个编程 agent 会话都是一个在上班的机器人。
读文件时去档案室，跑命令时去机房，需要你回复时到 CEO 办公室门口等，跨楼层坐电梯。

> 当前状态：早期版本。已支持 Claude Code 与 Codex，计划支持 WorkBuddy、DeepSeek Harness。

## 楼里各房间的含义

| 房间 | 含义 |
|---|---|
| 工位区 | 写代码 |
| 档案室 | 读文件、搜索 |
| 机房 | 跑命令 |
| 情报室 | 上网查资料 |
| 白板 | 做计划 |
| 会议室 | 派活给子 agent，或等它们做完 |
| CEO 办公室 | 等你回复，或做完后汇报 |
| 茶水间 | 做完了，休息中 |
| 睡眠舱 | 闲置的会话 |

机器人身上灯条的颜色代表职级，由模型决定；每个会话有自己的团队色。

## 环境要求

- macOS 15 及以上
- Swift 6 工具链（Xcode 16 或 Command Line Tools）

## 构建与运行

```sh
scripts/build-app.sh          # 生成 build/Agentrise.app
open build/Agentrise.app
```

然后打开 **设置 → Agent 接入 → Claude Code → 安装 Hooks**。写入前会先展示改动后的
`~/.claude/settings.json`，并备份原文件；只会添加 Agentrise 自己的异步 hook，卸载时也只删这几条。

### Codex

本机有 `~/.codex/` 时，设置里才会出现 Codex 一行（已在 Codex CLI 0.164 上实测）。

1. **设置 → Agent 接入 → Codex → 安装 Hook**。写入前会先展示改动后的 `~/.codex/hooks.json`，
   并备份原文件；只添加 Agentrise 自己的条目，不会直接改 `config.toml`。
2. Codex 要求先信任新 hook 才会运行它。Agentrise 会问要不要**替我确认**：同意后通过 Codex 自己的
   `app-server` 代为信任，和在 Codex 的 `/hooks` 界面里点信任是同一条路。不同意或代为信任失败时，
   在 Codex 里输入 `/hooks`，信任 Agentrise 的几条 hook 即可。
3. 收到第一个 Codex 事件后，这一行显示 **✓ 已生效**。

Codex 给的信息比 Claude Code 少，所以 Codex 的机器人不会显示：外包（后台命令）、上网查资料、发飞书。
`codex exec` 这类无界面运行不显示。Codex 退出 TUI 时不会通知 Agentrise，所以做完的 Codex 机器人
不会自己离开大楼，而是留在楼里（之后去睡眠舱）。

`swift test` 运行测试；`swift run agentrise-sim story` 会向正在运行的 App 发送一组模拟会话。
修改 `assets/*.svg` 后，运行 `swift scripts/make-icons.swift` 重新生成 PNG 和 `Resources/AppIcon.icns`。

## 隐私

hook 程序只在本机运行，通过只有当前用户能访问的 Unix socket 发送事件。它会丢掉 prompt 原文和文件内容，
命令、工具说明和最后一条回复只保留很短的片段。除非你开启可选的 Bark 推送，否则数据不会离开本机。

## 可选集成

- **Bark**：你离开电脑时，把「做完了 / 等你回复 / 出错」推送到 iPhone。
- **cc-connect（飞书）**：默认关闭；开启后，会把通过飞书转发的会话标注出来。

## 许可证

[MIT](LICENSE) © 2026 Colin Tay
