---
name: kagete
description: macOS computer-use CLI for agents. Use when the user wants to inspect, click, type, drag, scroll, or screenshot native macOS app windows — Safari, Finder, TextEdit, Xcode, Slack desktop, System Settings, any AppKit/Catalyst/SwiftUI app. Triggers include "click the Save button in X", "automate Finder", "read the AX tree of Y", "screenshot Xcode window", "type into TextEdit", "drag to reorder in Z", and any GUI task outside a browser. If the `kagete` binary is not on PATH, offer to install it with the one-liner in the Install section below.
allowed-tools: Bash(kagete:*), Bash(curl:*)
---

# kagete — macOS computer-use CLI

kagete gives agents **eyes and hands** for any macOS application through the Accessibility API and ScreenCaptureKit:

- **Eyes:** `inspect` (full AX tree) · `find` (filtered query) · `screenshot` (PNG) · `windows` (enumerate)
- **Hands:** `click` · `type` · `key` · `scroll` · `drag`

All output is JSON or newline-separated paths — designed for shell composition.

## Install

If `command -v kagete` returns nothing, run the one-liner (requires macOS 14+, Apple Silicon):

```bash
curl -fsSL https://raw.githubusercontent.com/ringotypowriter/kagete/main/install.sh | bash
```

Installs to `~/.local/bin/kagete`. The installer follows a GitHub redirect (no API token needed) and verifies SHA256 before install. After install, if `~/.local/bin` isn't on PATH, the installer prints the exact shell-rc line to add.

## Preflight

Run once per agent session (or when you see permission errors):

```bash
kagete doctor
```

If Accessibility or Screen Recording is missing, run `kagete doctor --prompt` and tell the user to approve the system dialogs. Without Accessibility, *all* input events silently drop.

## Two paths: AX and Visual

Different apps expose themselves to automation in very different ways. Pick the path that fits the target — switching is cheap.

### 1. AX path — the default, for well-behaved AppKit/SwiftUI apps

Safari, Finder, TextEdit, Xcode, System Settings, Notes, Mail, Slack desktop, most native SwiftUI/AppKit apps.

```
┌───────────┐    ┌───────────┐    ┌───────┐    ┌────────┐
│   FIND    │ →  │  LOCATE   │ →  │  ACT  │ →  │ VERIFY │
│  find     │    │ stable    │    │ click │    │ refind │
│  inspect  │    │ axPath    │    │ type  │    │ or     │
│           │    │           │    │ drag  │    │ screen │
└───────────┘    └───────────┘    └───────┘    └────────┘
```

- Queries: `kagete find --role AXButton --title-contains "Save"`
- Actions: `kagete click --ax-path '…'` — automatically uses `AXPress` when the element advertises it, which works on occluded or scrolled-off targets
- Stability: `axPath` survives resizes, redraws, theme changes
- Prefer this path when `find` returns what you're looking for with coords

### 2. Visual path — for custom-drawn / AX-hostile apps

Custom-drawn apps, Electron apps with optimized-away trees, games, canvas-based UIs, embedded webviews that hide text from AX. **Diagnostic: `find --value-contains <visible text>` returns `[]` for text clearly on screen → flip to Visual.**

```
┌──────────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────────┐
│  SCREENSHOT  │ →  │   READ   │ →  │  CLICK x,y   │ →  │   VERIFY       │
│  grid + crop │    │ coords   │    │ (with --x=   │    │  screenshot →  │
│  for zoom-in │    │ off grid │    │  for negs)   │    │  cursor cross  │
└──────────────┘    └──────────┘    └──────────────┘    └────────────────┘
```

- `kagete screenshot -o /tmp/s.png` — overlays a coordinate grid (200-pt pitch). Labels match `click --x --y` directly.
- `kagete screenshot --crop "x,y,w,h"` — zoom into a window-relative region. Labels still show absolute screen coords.
- After each click, the next screenshot renders a **pink crosshair** at the cursor's actual landing position plus a corner `cursor: (x, y)` badge. Use this to self-correct when you misread row positions.
- Negative x or y needs the `=` syntax: `--x=-1700 --y=1500`.

### Mental model

| App type | Signal | Path |
|---|---|---|
| AX-indexed element with AXPress | `find` returns it, `actions: ["AXPress"]` | AX + `--ax-path` |
| AX-indexed but custom-drawn | `find` returns it, `actions: null` | AX to locate frame center, then `click --x --y` at the center |
| No AX at all | `find` empty for visible text | Visual — screenshot grid + coords |
| Mixed (toolbar AX but body custom) | Search box indexed, result rows not | AX for the input, Visual for results |

**Never act without locating first.** Whether the handle is an `axPath`, an AX frame center, or a coord read off the grid — always locate before you click.

## Target Selection

Every command that operates on an app accepts these flags:

| Flag | Use when |
|---|---|
| `--app "Safari"` | Well-known app; matches localized name or executable |
| `--bundle com.apple.Safari` | Most stable; prefer when scripting long-lived workflows |
| `--pid 12345` | Last resort — PIDs change on every relaunch |
| `--window "GitHub"` | Narrow when an app has multiple windows (case-insensitive substring) |

If `--app` matches multiple running apps, kagete errors with a numbered list — narrow with `--bundle` or `--pid`.

## Commands at a Glance

| Command | Purpose | First reach for… |
|---|---|---|
| `kagete doctor` | Check permissions | Start of every session |
| `kagete windows` | List on-screen windows | "What's open right now?" |
| `kagete inspect` | Full AX tree of one window | Exploring unfamiliar UIs |
| `kagete find` | Filtered element search | **Default for locating a target** |
| `kagete screenshot` | Window → PNG with coordinate grid + cursor crosshair | Visual path; verify clicks |
| `kagete click` | Click by axPath or coords | Buttons, links, text fields |
| `kagete type` | Type text into focused element | After clicking a field |
| `kagete key` | Key combo (`cmd+s`, `return`, …) | Shortcuts, modal dismissals |
| `kagete scroll` | Wheel ticks | Long content, menus |
| `kagete drag` | Press → move → release | Select text, reorder lists, move items |

## Deep Dives

- [references/commands.md](references/commands.md) — every subcommand with all flags and realistic examples
- [references/ax-paths.md](references/ax-paths.md) — how `axPath` strings are built, sibling indexing, escaping rules
- [references/troubleshooting.md](references/troubleshooting.md) — AX-vs-Visual diagnosis, input-drop from event-tap interference (CleanShot, Zoom), activation fallback via `KAGETE_RAISE=ax`
- [guides/find-then-act.md](guides/find-then-act.md) — the canonical shell pipeline: locate → act in one flow
- [guides/pipelines.md](guides/pipelines.md) — ready-to-run multi-step recipes: search-and-select, fill a form, replace-text, visual-path end-to-end, wait-for-modal, scroll-to-find, right-click menu
- [guides/verify-loop.md](guides/verify-loop.md) — closed-loop verification with screenshots and re-queries

## Key Principles

1. **Try AX first, flip to Visual on evidence.** Start with `find`. If it returns the target with a resolvable frame, use the AX path. If `find` returns `[]` for text you can see on screen, the app is custom-drawn — switch to screenshot + coords without hesitation.
2. **Prefer `find` over `inspect`.** Most windows have 1000+ AX nodes. `find --role AXButton --title-contains "Save"` returns 1–5 hits; `inspect` returns everything.
3. **`axPath` beats coordinates when both exist.** Paths are stable across redraws; coords break on first resize.
4. **For Visual, always verify with the next screenshot.** The cursor crosshair shows exactly where the last click landed. If it's above/below the intended row, adjust y by the row-height delta and click again — don't keep guessing.
5. **Activation is automatic.** Input commands call `activate()` on the target app and wait 150 ms before firing events. Pass `--no-activate` to opt out.
6. **Events are paced internally.** Don't add `sleep` between kagete calls — 3 ms inter-event delays are already baked in.
7. **One target per command.** Chain with `&&` in the shell; don't try to batch multiple apps in one invocation.
8. **Output is JSON by default.** Use `--paths-only` on `find` for shell-friendly newline-separated paths.
