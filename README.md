# kagete

> macOS computer-use CLI for AI agents. Inspect, click, type, drag, scroll, and screenshot any native macOS app window through the Accessibility API and ScreenCaptureKit.

```text
┌───────────┐    ┌───────────┐    ┌───────┐    ┌────────┐
│   SEE     │ →  │  LOCATE   │ →  │  ACT  │ →  │ VERIFY │
│  find/    │    │ pick a    │    │ click │    │ screen │
│  inspect/ │    │ stable    │    │ type  │    │ shot / │
│  screen   │    │ axPath    │    │ drag  │    │ refind │
└───────────┘    └───────────┘    └───────┘    └────────┘
```

`agent-browser`-style ergonomics, but for native macOS — Safari, Finder, TextEdit, Xcode, Slack desktop, System Settings, any AppKit/Catalyst/SwiftUI app.

## Install

Requires macOS 14+, Apple Silicon.

```sh
curl -fsSL https://raw.githubusercontent.com/ringotypowriter/kagete/main/install.sh | bash
```

Installs to `~/.local/bin/kagete`. Overrides:

- `KAGETE_INSTALL_DIR=/usr/local/bin` for a different destination
- Add `~/.local/bin` to `PATH` if it isn't already (the installer prints exact commands)

### From source

```sh
git clone https://github.com/ringotypowriter/kagete.git
cd kagete
swift build -c release
cp .build/release/kagete ~/.local/bin/kagete
```

## First run — permissions

kagete needs two macOS privacy permissions:

```sh
kagete doctor --prompt
```

This triggers the system dialogs for:

- **Accessibility** — to read AX trees and post synthesized mouse/keyboard events
- **Screen Recording** — to capture window PNGs via ScreenCaptureKit

Grant both in System Settings → Privacy & Security. Without Accessibility, input events silently drop.

## Commands

| Command | What | Example |
|---|---|---|
| `doctor` | Check permissions | `kagete doctor` |
| `windows` | List on-screen windows | `kagete windows --app Safari` |
| `inspect` | Full AX tree of a window | `kagete inspect --app Safari --max-depth 6` |
| `find` | Filtered element search | `kagete find --app Safari --role AXButton --title-contains Save` |
| `screenshot` | Window → PNG | `kagete screenshot --app Safari -o shot.png` |
| `click` | Click at axPath or coords | `kagete click --app Safari --ax-path '…/AXButton[title="Save"]'` |
| `type` | Type text into focused element | `kagete type --app TextEdit "hello 🌍"` |
| `key` | Keyboard combo | `kagete key --app Safari cmd+t` |
| `scroll` | Wheel ticks | `kagete scroll --dy -5` |
| `drag` | Press → move → release | `kagete drag --from-x 100 --from-y 200 --to-x 400 --to-y 200` |
| `release` | Tell the overlay the agent is done | `kagete release` |

Every command emits JSON by default. Use `--paths-only` on `find` for shell-friendly pipelines.

## Quickstart

```sh
# Discover a button
kagete find --app Safari --role AXButton --title-contains "Reload" --paths-only
# → /AXWindow/AXToolbar/AXButton[title="Reload this page"]

# Click it
kagete click --app Safari --ax-path '/AXWindow/AXToolbar/AXButton[title="Reload this page"]'

# Type into a field
kagete click --app Mail --ax-path '…/AXTextField[title="To:"]'
kagete type  --app Mail "leader@example.com"

# Shortcut
kagete key --app TextEdit cmd+s

# Agent signals completion
kagete release
```

### Target selection

Every command that acts on a specific app takes one of:

| Flag | When |
|---|---|
| `--app "Safari"` | Most ergonomic — matches localized or executable name |
| `--bundle com.apple.Safari` | Most stable — survives renames and locale changes |
| `--pid 12345` | Escape hatch (PIDs are ephemeral) |
| `--window "GitHub"` | Narrow when an app has multiple windows |

## Awareness overlay

Whenever kagete takes an action, a small pill slides out from below the notch (or top of the screen on Macs without one) — `🤖 kagete · TextEdit · click`. Users know the agent is driving without reading logs. The overlay:

- Auto-spawns on first input command; no background process when idle
- Reuses across subsequent commands within a 10-second window
- Auto-retires with a `✓ control returned` ceremony on idle, or immediately via `kagete release`
- Never steals focus (`NSPanel + .nonactivatingPanel + .transient`, with `NSApp.deactivate()` after every update)

Customize or disable:

```sh
KAGETE_OVERLAY=0 kagete click …               # silent, no pill
KAGETE_OVERLAY_LABEL=Exusiai kagete click …   # "Exusiai · TextEdit · click"
kagete overlay status                          # query helper state
kagete overlay stop                            # force-retire the helper
```

## AX paths

kagete identifies elements with `axPath` strings, slash-separated from window root:

```
/AXWindow[id="_NS:34"]/AXScrollArea[id="_NS:8"]/AXTextArea[id="First Text View"]
/AXWindow/AXToolbar/AXButton[title="Reload"]
/AXWindow/AXOutline/AXRow[0]/AXCell
```

Paths survive resizes, redraws, and theme changes. Re-run `find` if the UI's structure changes (modals open, rows added, etc.). See [skills/references/ax-paths.md](skills/references/ax-paths.md) for the full grammar.

## Agent skill

A Claude Code skill at [`skills/`](skills/) teaches LLM agents how to use kagete:

```sh
ln -s "$PWD/skills" ~/.claude/skills/kagete
```

Includes a compact hub (`SKILL.md`), full command reference (`references/commands.md`), path grammar (`references/ax-paths.md`), canonical `find → act` pipeline (`guides/find-then-act.md`), and verification patterns (`guides/verify-loop.md`).

## Development

```sh
swift test                           # unit tests
swift build                          # debug build
swift build -c release               # release binary
.build/debug/kagete <subcommand>     # run without install
```

## License

MIT — see [LICENSE](LICENSE).
