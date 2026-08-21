<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="CCBar icon">
</p>

<h1 align="center">cc-bar</h1>

<p align="center">A macOS menu bar utility: real-time remaining quota for Codex, Claude Code, and Antigravity,<br>plus local token usage and cost statistics.</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="swiftui" src="https://img.shields.io/badge/SwiftUI-F05138?logo=swift&logoColor=white">
  <a href="https://github.com/nanvon/cc-bar/releases/latest"><img alt="release" src="https://img.shields.io/github/v/release/nanvon/cc-bar?color=brightgreen"></a>
  <img alt="downloads" src="https://img.shields.io/github/downloads/nanvon/cc-bar/total?color=blue">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-orange">
</p>

<p align="center">
  <a href="https://github.com/nanvon/cc-bar/releases/latest">Download</a> ·
  <a href="#-installation">Install</a> ·
  <a href="#-building-from-source">Build from source</a> ·
  <a href="#-related-projects">Related projects</a> ·
  <a href="https://github.com/nanvon/cc-bar/issues">Feedback</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/Screenshots/popover-light.png" width="360" alt="Popover overview - light mode">
  <img src="docs/Screenshots/popover-dark.png" width="360" alt="Popover overview - dark mode">
</p>

## ✨ Features

- **Quota overview** — remaining 5-hour / weekly window quota for Codex, Claude Code, and Antigravity; the menu bar icon shows the remaining percentage
- **Floating HUD** — optional desktop overlay; draggable, snaps to screen edges, stays on top without stealing focus
- **Multiple Codex accounts** — import multiple Codex accounts and see primary and secondary side by side in the popover; per-account bonus reset counts and expiry dates in Settings
- **Usage statistics** — token and cost totals for Codex, Claude Code, Pi, and OpenCode, by today / yesterday / this week / this month / this year / last 7 days / last 30 days / all time / custom range, broken down by service, by model, by individual conversation, and by model provider, with a daily usage chart
- **Cycle usage** — per-reset-window token and cost stats for the primary Codex / Claude accounts, with a full-cycle projection and reset countdown
- **Quota timeline** — a record of how the 5-hour window quota changed over time
- **Service status** — OpenAI / Anthropic statuspage dots in the popover
- **Preferences** — account toggles, menu bar display options, floating HUD, refresh interval, service status, price catalog updates, usage recalculation, reset-time display, privacy mode, English/Chinese UI, launch at login

### 📸 Screenshots

<p align="center">
  <img src="docs/Screenshots/statistics-overview.png" width="720" alt="Usage statistics - overview"><br>
  <sub>Overview: token / cost totals, split by service and model</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-conversations.png" width="720" alt="Usage statistics - conversations"><br>
  <sub>Conversations: per-conversation token and cost breakdown</sub>
</p>

<p align="center">
  <img src="docs/Screenshots/statistics-timeline.png" width="720" alt="Usage statistics - timeline"><br>
  <sub>Timeline: 5-hour window quota over time</sub>
</p>

## 📦 Installation

🍎 Requires macOS 14 (Sonoma) or later. Codex / Claude Code must already be logged in via their CLIs; Antigravity requires the official app or IDE to be installed and running to provide the local quota service.

1. Download `CCBar.dmg` (or the fallback `CCBar.app.zip`) from [Releases](https://github.com/nanvon/cc-bar/releases/latest) and drag `CCBar.app` into `/Applications`.
2. CCBar is not notarized by Apple, so Gatekeeper blocks the first launch: after the blocked attempt, open **System Settings → Privacy & Security**, scroll down to the CCBar prompt, and click **"Open Anyway"**.
3. If `~/.claude/.credentials.json` does not exist on your Mac, the app shows an explanation and then asks for Keychain access — choose **"Always Allow"**.

> [!NOTE]
> Since macOS Sequoia, the old "right-click → Open" workaround no longer works; the System Settings path above is the only way.
> If you still see "app is damaged", remove the quarantine attribute manually in Terminal:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/CCBar.app
> ```

## 🔒 Data & Security

cc-bar is a small open-source tool built for personal use. To query quotas, it reads local credentials:

- Codex: `~/.codex/auth.json`
- Claude Code: `~/.claude/.credentials.json` and the macOS Keychain
- Antigravity: only connects to the local Language Server the official process exposes on `127.0.0.1`; it does not store Google OAuth credentials, launch the CLI, or send model requests

Usage statistics are computed from local session logs: the JSONL logs of Codex (`~/.codex/sessions` and `~/.codex/archived_sessions`), Claude Code (`~/.claude/projects`), and Pi (the pi coding agent; under `~/.pi/agent/sessions`), plus OpenCode's SQLite session database (`~/.local/share/opencode/opencode.db`, opened read-only).

> [!TIP]
> The released `CCBar.app` is ad-hoc signed and not notarized. If that concerns you, review the code yourself and [build from source](#-building-from-source) instead of relying on the released binaries.

## 🔧 Building from Source

Requires the full Xcode (Command Line Tools alone are not enough).

**Daily development**: open `ccbar.xcodeproj`, pick the `ccbar` scheme and "My Mac", then run with **⌘R**.

**Release packaging**:

```bash
# One-time: point the command line tools at the full Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Release build + packaging; outputs dist/CCBar.dmg and dist/CCBar.app.zip
./scripts/build.sh
```

The script builds with `CODE_SIGNING_ALLOWED=NO`; the ad-hoc signed output runs on any Mac, no paid certificate or notarization required.

> [!WARNING]
> Do not distribute via Xcode's Archive export: it embeds an "Apple Development" certificate, and the app will only run on your own machine.

## 🔗 Related Projects

Three apps by the same author, sharing the same quota semantics and visual language:

|                                                                  |                                          |
| ---------------------------------------------------------------- | ---------------------------------------- |
| **cc-bar** (this repository)                                     | Native macOS menu bar version (SwiftUI)  |
| [**CC Trace**](https://github.com/nanvon/cc-trace)               | Desktop · macOS menu bar / Windows tray  |
| [**CC Trace Mobile**](https://github.com/nanvon/cc-trace-mobile) | Mobile · iOS / Android                   |

CC Trace rebuilds cc-bar's feature set on Tauri to support both macOS and Windows. The three apps are independent; data and settings are not shared.

## 🙏 Acknowledgments

The design and implementation drew on these open-source projects:

- [cc-switch](https://github.com/farion1231/cc-switch) — multi-provider account switcher; inspired the multi-account management and import flow
- [cockpit-tools](https://github.com/jlcodes99/cockpit-tools) — multi-platform AI coding assistant dashboard; a reference for quota and refresh strategies
- [CodexBar](https://github.com/steipete/CodexBar) — macOS menu bar AI usage monitor; informed the menu bar interaction and local parsing approach

## 📄 License

[MIT](LICENSE)
