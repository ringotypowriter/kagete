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

kagete exposes narrow primitives. Every command does exactly one thing; fallback and sequencing are the agent's job.

| Layer | Command | What | Example |
|---|---|---|---|
| Setup | `doctor` | Check permissions | `kagete doctor` |
| Read | `windows` | List on-screen windows | `kagete windows --app Safari` |
| Read | `inspect` | Full AX tree of a window | `kagete inspect --app Safari --max-depth 6` |
| Read | `find` | Filtered element search | `kagete find --app Safari --role AXButton --text-contains Save` |
| Read | `screenshot` | Window → PNG | `kagete screenshot --app Safari -o shot.png` |
| AX | `press` | Fire `AXPress` on an element | `kagete press --app Safari --ax-path '…/AXButton[title="Reload"]'` |
| AX | `action` | Fire a named AX action | `kagete action --app Finder --ax-path '…/AXRow[0]' --name AXShowMenu` |
| AX | `focus` | Set `kAXFocusedAttribute = true` | `kagete focus --app Safari --ax-path '…/AXTextField[title="Address"]'` |
| AX | `set-value` | Write `kAXValueAttribute` (background text input) | `kagete set-value --app Safari --ax-path '…' "hello"` |
| AX | `scroll-to` | Fire `AXScrollToVisible` | `kagete scroll-to --app Xcode --ax-path '…/AXRow[42]'` |
| App | `activate` | Bring the app to foreground (`--method app\|ax\|both`) | `kagete activate --app Safari` |
| App | `raise` | AX-level window raise | `kagete raise --app TextEdit` |
| HID | `click-at` | CGEvent click at `(x, y)` — no warp, no activate | `kagete click-at --x 640 --y 480` |
| HID | `move` | Warp the cursor to `(x, y)` | `kagete move --x 320 --y 240` |
| HID | `type` | Synthesize Unicode text (PID-targeted when `--app` is set) | `kagete type --app TextEdit "hello 🌍"` |
| HID | `key` | Single key combo | `kagete key --app Safari cmd+t` |
| HID | `scroll` | Wheel ticks at current cursor position | `kagete scroll --dy -5` |
| HID | `drag` | Press → move → release | `kagete drag --from-x 100 --from-y 200 --to-x 400 --to-y 200` |
| Control | `wait` | Poll for element / window / value | `kagete wait --app TextEdit --role AXButton --text-contains OK` |
| Overlay | `release` | Retire the awareness overlay | `kagete release` |

Every command emits JSON by default. Use `--paths-only` on `find` for shell-friendly pipelines.

## Quickstart

```sh
# Discover a button
kagete find --app Safari --role AXButton --text-contains "Reload" --paths-only
# → /AXWindow/AXToolbar/AXButton[title="Reload this page"]

# Press it (AX semantic — works on backgrounded windows, no cursor movement)
kagete press --app Safari --ax-path '/AXWindow/AXToolbar/AXButton[title="Reload this page"]'

# Fill a text field — two flavors:
#   (a) background AX write, no focus theft
kagete set-value --app Mail --ax-path '…/AXTextField[title="To:"]' "leader@example.com"
#   (b) keyboard synthesis with explicit focus
kagete focus --app Mail --ax-path '…/AXTextField[title="To:"]'
kagete type  --app Mail "leader@example.com"

# Shortcut — menu shortcuts generally need the app frontmost first
kagete activate --app TextEdit
kagete key      --app TextEdit cmd+s

# Coordinate click — pure CGEvent at (x, y), no warp, no activate
kagete click-at --x 640 --y 480

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
KAGETE_OVERLAY=0 kagete press …                # silent, no pill
KAGETE_OVERLAY_LABEL=Exusiai kagete press …    # "Exusiai · TextEdit · press"
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

Paths survive resizes, redraws, and theme changes. Re-run `find` if the UI's structure changes (modals open, rows added, etc.). See [skills/kagete/references/ax-paths.md](skills/kagete/references/ax-paths.md) for the full grammar.

## Agent skill

A Claude Code skill at [`skills/kagete/`](skills/kagete/) teaches LLM agents how to use kagete.

**Install with one command:**

```sh
npx skills add ringotypowriter/kagete
```

Or manually with a symlink:

```sh
ln -s "$PWD/skills/kagete" ~/.claude/skills/kagete
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
