---
name: kagete
description: Use this skill when you need to inspect, click, type, drag, scroll, or screenshot native macOS app windows — Safari, Finder, TextEdit, Xcode, Slack desktop, System Settings, or any other native macOS application. Triggers include requests like "click the Save button in X", "automate Finder", "read the AX tree of Y", "screenshot Xcode window", "type into TextEdit", "drag to reorder in Z", and any GUI task outside a browser.
allowed-tools: Bash(kagete:*), Bash(curl:*)
---

# kagete — macOS computer-use CLI

kagete gives agents **eyes and hands** for any macOS application through the Accessibility API and ScreenCaptureKit:

- **Eyes:** `inspect` (full AX tree) · `find` (filtered query) · `screenshot` (PNG) · `windows` (enumerate)
- **Hands:** `click` · `type` · `key` · `scroll` · `drag`

Every command emits a uniform JSON envelope on stdout — `{ok, command, target, result, verify, hint, error}` — so agents branch on `ok` + `error.code` instead of parsing per-command shapes. See [Output Envelope](#output-envelope) below.

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

## Output Envelope

Every command writes a single JSON object to stdout:

```json
{
  "ok": true,
  "command": "click",
  "target":  { "pid": 1234, "app": "Safari", "bundle": "com.apple.Safari", "window": "GitHub" },
  "result":  { "method": "ax-press", "button": "left", "count": 1, "point": {...}, "element": {...} },
  "verify":  { "cursor": {...} },
  "hint":    "optional machine-readable next-step"
}
```

On failure the shape flips to `{ok:false, command, target?, error:{code, message, retryable, hint?}}` and exit code is non-zero. A short human line also goes to stderr.

**Branch on `ok` + `error.code` — never string-match `.message`.**

`ErrorCode` vocabulary (stable contract):

| Code | When | Retryable |
|---|---|---|
| `PERMISSION_DENIED` | Accessibility or Screen Recording not granted | no |
| `INVALID_ARGUMENT` | Bad flags or values (`--button foo`, empty `--crop`, missing filters) | no |
| `TARGET_NOT_FOUND` | `--app/--bundle/--pid` didn't match any running app | no |
| `AMBIGUOUS_TARGET` | `--app "Claude"` matched multiple apps | no — narrow with `--bundle`/`--pid` |
| `AX_ELEMENT_NOT_FOUND` | `--ax-path` didn't resolve in the current tree | no — re-`find` |
| `AX_NO_FRAME` | Element located but frame is empty/hidden | no |
| `SCK_TIMEOUT` | ScreenCaptureKit hung past the 15 s guard | **yes** |
| `INTERNAL` | Genuine runtime/invariant failure | no |

Key fields to know:

- **`result`** — command-specific success payload (see [references/commands.md](references/commands.md))
- **`verify`** — post-action state snapshot. For `type`/`key`, `verify.focusedRole` + `focusedTitle` tell you which element received the input, without a follow-up `inspect`/`screenshot`. For `click`/`drag`, `verify.cursor` shows the actual cursor position after input — use it to confirm the click landed at the requested point. (Click verify intentionally omits `focusedRole`: app focus is unrelated to "what was clicked" — re-`find` or `screenshot` if you need to verify the click target itself.)
- **`hint`** — machine-readable next-step when kagete can infer one (e.g. `"Hit --limit (50) — narrow with --enabled-only"`). Absent when none applies.

Every action command accepts `--text` (or equivalent, documented per command) to emit a terse one-liner instead of the envelope — handy for humans running commands interactively. `kagete find --paths-only` stays as plain newline-separated axPath strings for shell piping.

## Key Principles

1. **Try AX first, flip to Visual on evidence.** Start with `find`. If `result.count == 0` for text you can see on screen, the app is custom-drawn — switch to screenshot + coords without hesitation.
2. **Prefer `find` over `inspect --tree`.** Most windows have 1000+ AX nodes. `inspect` (default) returns a compact summary — use it only for survey. `find --role AXButton --title-contains "Save"` is the targeted query.
3. **`axPath` beats coordinates when both exist.** Paths are stable across redraws; coords break on first resize.
4. **Read `verify` before re-screenshotting.** For `type`/`key` it gives you the focused element post-action; for `click`/`drag` it gives the actual cursor coord. Only screenshot to confirm when `verify` is insufficient — e.g. you need to know what UI the click *hit* (not just where the cursor went), or anything visual-only.
5. **Activation is automatic.** Input commands call `activate()` on the target app and wait 150 ms before firing events. Pass `--no-activate` to opt out.
6. **Sleep between semantic steps, not inside them.** kagete paces low-level events (mouse-down → mouse-up, inter-keystroke) internally — don't wrap those. But between distinct high-level steps (click → menu renders, type → network request returns, `key cmd+s` → save dialog appears), **add a short `sleep`** so the app has time to transition before the next kagete call reads its post-action state. Typical values: `sleep 0.2` after menu/context opens, `sleep 0.3–0.5` after a modal or view transition, poll loops with `sleep 0.25` for network-bound waits. Without these, `find`/`screenshot` may run before the UI has caught up and return stale state.
7. **Chain sequential steps in one bash/exec call.** A pipeline of `kagete click && sleep 0.2 && kagete key && …` should live in **one** shell invocation, not split across multiple tool calls. Each tool-call boundary costs latency and context; chaining with `&&` keeps the sequence atomic (a failing step aborts the rest) and couples each action with its post-step sleep in one place. Reserve separate tool calls for branching on the **result** of a previous pipeline — not for stepping through a fixed sequence.
8. **One target per command.** Chain sub-steps of a single-app flow; don't try to batch multiple apps inside one `kagete` invocation.
9. **Error-code branching, not message parsing.** `jq -e '.ok'` to gate; `jq -r '.error.code'` to route. Messages are for humans; codes are for you.
