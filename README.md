# Agentrise

A tiny office tower on your Mac desktop where every coding-agent session is a robot at work.
Sessions walk to the archive when they read files, to the server room when they run commands,
wait at the CEO's office when they need you, and take the elevator between floors.

[中文说明](README.zh-CN.md)

> Status: early. Claude Code is supported today; Codex, WorkBuddy and DeepSeek Harness
> adapters are planned. The UI is currently in Chinese.

## What you see

| Room | Meaning |
|---|---|
| Desks | writing code |
| Archive | reading / searching files |
| Server room | running shell commands |
| Intel room | browsing the web |
| Whiteboard | planning |
| Meeting room | delegating to sub-agents, or waiting for them |
| CEO office | waiting for your reply, or reporting a finished task |
| Pantry | done, resting |
| Sleep pods | idle sessions |

Robot rank (stripe color) follows the model, and each session keeps its own team color.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16 or the Command Line Tools)

## Build and run

```sh
scripts/build-app.sh          # builds build/Agentrise.app
open build/Agentrise.app
```

Then open **Settings → Claude Code Hooks → Install**. Agentrise shows the exact
`~/.claude/settings.json` it will write, backs up the old file, and only adds its own
async hooks. Uninstall removes exactly those entries.

`swift test` runs the test suite. `swift run agentrise-sim story` sends a scripted
set of fake sessions to a running app.

## Privacy

The hook helper runs locally and sends events over a Unix socket that only your user can
open. It drops prompt text and file contents, and clips commands, tool descriptions and the
last assistant message to short excerpts. Nothing leaves your machine unless you enable
the optional Bark push integration.

## Optional integrations

- **Bark** — push "done / waiting / error" to your iPhone when you are away from the desk.
- **cc-connect (Feishu)** — off by default; when enabled, sessions bridged to Feishu chats
  are labelled as such.

## License

[MIT](LICENSE) © 2026 Colin Tay
