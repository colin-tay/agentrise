<p align="center"><img src="assets/logo-256.png" width="128" alt="Agentrise logo"></p>

<h1 align="center">Agentrise</h1>

一栋放在 Mac 桌面上的小写字楼：每个编程 agent 会话都是一个在上班的机器人。
读文件时去档案室，跑命令时去机房，需要你回复时到 CEO 办公室门口等，跨楼层坐电梯。

> 当前状态：早期版本。已支持 Claude Code，计划支持 Codex、WorkBuddy、DeepSeek Harness。

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

然后打开 **设置 → Claude Code Hooks → 安装 Hooks**。写入前会先展示改动后的
`~/.claude/settings.json`，并备份原文件；只会添加 Agentrise 自己的异步 hook，卸载时也只删这几条。

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
