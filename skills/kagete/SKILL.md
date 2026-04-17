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

## Core Loop (follow every task)

```
┌───────────┐    ┌───────────┐    ┌───────┐    ┌────────┐
│   SEE     │ →  │  LOCATE   │ →  │  ACT  │ →  │ VERIFY │
│  find/    │    │ pick a    │    │ click │    │ screen │
│  inspect/ │    │ stable    │    │ type  │    │ shot / │
│  screen   │    │ axPath    │    │ drag  │    │ refind │
└───────────┘    └───────────┘    └───────┘    └────────┘
```

**Never act without locating first.** Coordinates are a fallback, not the primary handle — an `axPath` survives window resizes, layout reflows, and theme changes.

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
| `kagete screenshot` | Window → PNG | Visual reasoning + verify |
| `kagete click` | Click by axPath or coords | Buttons, links, text fields |
| `kagete type` | Type text into focused element | After clicking a field |
| `kagete key` | Key combo (`cmd+s`, `return`, …) | Shortcuts, modal dismissals |
| `kagete scroll` | Wheel ticks | Long content, menus |
| `kagete drag` | Press → move → release | Select text, reorder lists, move items |

## Deep Dives

- [references/commands.md](references/commands.md) — every subcommand with all flags and realistic examples
- [references/ax-paths.md](references/ax-paths.md) — how `axPath` strings are built, sibling indexing, escaping rules
- [references/troubleshooting.md](references/troubleshooting.md) — input-drop diagnosis, event-tap interference (CleanShot, Zoom), activation fallback via `KAGETE_RAISE=ax`
- [guides/find-then-act.md](guides/find-then-act.md) — the canonical shell pipeline: locate → act in one flow
- [guides/verify-loop.md](guides/verify-loop.md) — closed-loop verification with screenshots and re-queries

## Key Principles

1. **Prefer `find` over `inspect`.** Most windows have 1000+ AX nodes. `find --role AXButton --title-contains "Save"` returns 1–5 hits; `inspect` returns everything.
2. **`axPath` beats coordinates.** Paths are stable across redraws; coords break on first resize.
3. **Activation is automatic.** Input commands call `activate()` on the target app and wait 150 ms before firing events. Pass `--no-activate` to opt out.
4. **Events are paced internally.** Don't add `sleep` between kagete calls — 3 ms inter-event delays are already baked in.
5. **One target per command.** Chain with `&&` in the shell; don't try to batch multiple apps in one invocation.
6. **Output is JSON by default.** Use `--paths-only` on `find` for shell-friendly newline-separated paths.
