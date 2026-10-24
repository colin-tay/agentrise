<p align="center"><img src="assets/logo-256.png" width="128" alt="Agentrise logo"></p>

<h1 align="center">Agentrise</h1>

A tiny office tower on your Mac desktop where every coding-agent session is a robot at work.
Sessions walk to the archive when they read files, to the server room when they run commands,
wait at the CEO's office when they need you, and take the elevator between floors.

[中文说明](README.zh-CN.md)

> Status: early. Claude Code and Codex are supported; WorkBuddy and DeepSeek Harness
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

Then open **Settings → Agent 接入 (Agents) → Claude Code → 安装 Hooks (Install)**. Agentrise
shows the exact `~/.claude/settings.json` it will write, backs up the old file, and only adds
its own async hooks. Uninstall removes exactly those entries.

### Codex

The Codex row appears once `~/.codex/` exists (tested with Codex CLI 0.164).

1. **Settings → Agent 接入 → Codex → 安装 Hook (Install)**. Agentrise shows the
   `~/.codex/hooks.json` it will write, backs up the old file, and only adds its own entries.
   It never edits `config.toml` itself.
2. Codex runs a new hook only after you trust it. Agentrise offers to do that for you
   (**替我确认**, "confirm for me"), through Codex's own `app-server`, the same way Codex's
   `/hooks` screen does. If you decline, or it fails, type `/hooks` in Codex and trust the
   Agentrise entries there.
3. Start a new Codex session to pick up the hook; sessions already running won't.
4. The row shows **✓ 已生效** (working) once the first Codex event arrives.

Codex sends less than Claude Code, so some things never show up for Codex robots:
contractors (background commands), browsing the web, and Feishu messages. `codex exec`
runs are not shown. Codex does not report quitting its TUI, so a finished Codex robot
stays in the building (eventually asleep) instead of leaving.

`swift test` runs the test suite. `swift run agentrise-sim story` sends a scripted
set of fake sessions to a running app. After editing `assets/*.svg`, run
`swift scripts/make-icons.swift` to regenerate the PNGs and `Resources/AppIcon.icns`.

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
