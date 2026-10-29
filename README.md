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

## Windows (experimental)

An experimental Windows build exists: the same tower, sessions and art, in a window with a tray icon.
It is **unsigned** and has had little testing on real machines. It needs Windows 10 version 1809 or
later, or Windows 11, on x64.

**Download.** Zips named `Agentrise-windows-x64-<version>.zip` appear on the
[Releases](https://github.com/colin-tay/agentrise/releases) page when one is published. There is no
installer: unzip into a folder of its own (the files must stay together) and double-click
`Agentrise.exe`. The Swift and Visual C++ runtime DLLs ship next to it, so nothing else needs
installing. (If Windows still reports a missing `VCRUNTIME140.dll`
or `MSVCP140.dll`, install Microsoft's
[Visual C++ v14 Redistributable (x64)](https://aka.ms/vc14/vc_redist.x64.exe).)

**First run.**

- **SmartScreen** stops unsigned programs it hasn't seen before ("Windows protected your PC").
  Choose **More info → Run anyway**.
- **Smart App Control** blocks unsigned programs outright, with no way to run them. If it is on,
  this build won't start. Check it in **Settings → Privacy & security → Windows Security → App &
  browser control → Smart App Control**.

**What works.** The tower window (landscape and portrait) with the pending panel; the tray icon with
the waiting count, flashing when a session starts waiting; Claude Code and Codex hooks installed from
**Settings…** in the tray menu (previewed, the old file backed up; the hook is copied to
`%LOCALAPPDATA%\Agentrise\bin\`, so moving the unzipped folder later doesn't break it); ranks;
start at sign-in; always on top; one instance; clicking a robot to jump back to its session.

**Known limitations.**

- Unsigned (see above). x64 only; on Windows 11 ARM it runs through Windows' x64 emulation.
- Clicking a terminal session brings its terminal window forward, not the tab. Jumping to a Claude
  desktop-app session uses its `claude://` link, which is unverified on Windows.
- Not on Windows: Bark push, sounds, and cc-connect (Feishu) session recognition.
- Emoji inside text (the ⚡ on name plates) are drawn about 20% smaller than on macOS.
- Things only checked by reading code and docs, not yet on a real machine: Claude Code versions
  without the hook `args` field, Codex's shell for hooks and its trust prompt, npm-installed Codex,
  per-monitor DPI changes, running as administrator.

Found a problem? [Open a Windows issue](https://github.com/colin-tay/agentrise/issues/new?template=windows.yml).

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
