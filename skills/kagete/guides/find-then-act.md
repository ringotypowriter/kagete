# Find-Then-Act — The Canonical Pipeline

Every kagete-driven task boils down to: discover an axPath with `find`, then act on it with `click`/`type`/`drag`/`key`. This guide shows the standard shapes.

## The Mental Model

```
kagete find …  ──▶  axPath  ──▶  kagete click --ax-path …
                               or kagete type …
                               or kagete drag --from-ax-path …
```

Always **re-find** after anything that changes app state (clicks, navigation, modal open/close). Paths are stable under redraws but not under structural changes.

---

## Recipe 1 — Click a Button by Title

```bash
# 1. Locate
kagete find --app Safari --role AXButton --title-contains "Reload" --paths-only
# → /AXWindow/AXToolbar/AXButton[title="Reload this page"]

# 2. Act
kagete click --app Safari \
  --ax-path '/AXWindow/AXToolbar/AXButton[title="Reload this page"]'
```

### One-liner (fish shell)

```fish
set p (kagete find --app Safari --role AXButton --title-contains "Reload" --paths-only | head -1)
and kagete click --app Safari --ax-path $p
```

### One-liner (bash / zsh)

```bash
p=$(kagete find --app Safari --role AXButton --title-contains "Reload" --paths-only | head -1)
[ -n "$p" ] && kagete click --app Safari --ax-path "$p"
```

---

## Recipe 2 — Type into a Field

```bash
# Find the field
kagete find --app Mail --role AXTextField --title-contains "To" --paths-only
# → /AXWindow/AXSplitGroup/…/AXTextField[title="To:"]

# Click to focus it
kagete click --app Mail --ax-path '/AXWindow/…/AXTextField[title="To:"]'

# Type — events go to the now-focused field
kagete type --app Mail "leader@example.com"
```

**Tip:** `kagete type` doesn't clear existing content. To replace:

```bash
kagete key --app Mail cmd+a         # select all
kagete key --app Mail delete        # clear
kagete type --app Mail "new value"
```

---

## Recipe 3 — Select Text via Drag

```bash
# Get the text area's frame
kagete find --app TextEdit --role AXTextArea
# → frame: { x: 120, y: 118, width: 2303, height: 1200 }

# Drag across a known region (line 1 of the document)
kagete drag --app TextEdit \
  --from-x 130 --from-y 132 \
  --to-x 500 --to-y 132

# Or: select-all via keyboard (safer for unknown layouts)
kagete key --app TextEdit cmd+a
```

---

## Recipe 4 — Open a Menu, Pick an Item

macOS menus are AX-inspectable but their paths vary. The keyboard route is usually faster:

```bash
# File → Save As…
kagete key --app TextEdit cmd+shift+s

# If no shortcut, traverse AXMenuBar:
kagete find --app Safari --role AXMenuItem --title "Develop" --paths-only
kagete click --app Safari --ax-path '…'   # opens the menu
kagete find --app Safari --role AXMenuItem --title "Show Web Inspector" --paths-only
kagete click --app Safari --ax-path '…'
```

---

## Recipe 5 — Wait for an Element to Appear

kagete has no built-in wait. Poll with `find`:

```bash
# Bash: retry up to 20× at 250ms intervals
for i in {1..20}; do
  path=$(kagete find --app Foo --title-contains "Loading" --paths-only 2>/dev/null)
  [ -z "$path" ] && break   # "Loading" gone → page ready
  sleep 0.25
done
```

Or wait *for* something to appear:

```bash
for i in {1..20}; do
  path=$(kagete find --app Foo --title "Continue" --paths-only 2>/dev/null | head -1)
  [ -n "$path" ] && kagete click --app Foo --ax-path "$path" && break
  sleep 0.25
done
```

---

## Recipe 6 — Walk a List / Table

```bash
# Get all rows in a Finder outline
kagete find --app Finder --role AXRow --paths-only
# /AXWindow/AXOutline/AXRow[0]
# /AXWindow/AXOutline/AXRow[1]
# /AXWindow/AXOutline/AXRow[2]
# …

# Click the third one
kagete click --app Finder --ax-path '/AXWindow/AXOutline/AXRow[2]'
```

---

## Anti-Patterns

| Don't | Because |
|---|---|
| `kagete inspect` then `jq`/`grep` the full tree | Use `find` with filters — it's already the targeted query |
| Hardcode pixel coordinates | They break on resize, DPI change, theme switch |
| Cache an axPath across state-changing actions | Re-`find` after every click/nav/modal |
| `sleep` between kagete commands | Inter-event delays are already baked in; only sleep for app-side async work |
| Batch multiple apps in one invocation | One target per command, chain with `&&` |

---

## Failure Modes & Quick Fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: No AX windows for pid N` | App closed or hid its windows | Reopen the app, confirm with `kagete windows` |
| `Error: No window matching "X"` | Title substring wrong | Run `kagete windows --app Foo` to see actual titles |
| `Error: No AX element matches path …` | Tree shifted since you got the path | Re-run `find`, pick a fresh path |
| `Accessibility permission not granted` | System privacy gate | `kagete doctor --prompt`, then user approves in System Settings |
| Events seem to vanish | Target app isn't focused | Make sure `--no-activate` isn't set; confirm window is frontmost |
