# Pipeline Patterns — Ready-to-Run Sequences

Common multi-step workflows an agent can follow verbatim and adapt. Each pipeline is designed to be **copy-friendly** — the agent can swap app names and query strings without rethinking the shape.

Read [find-then-act.md](find-then-act.md) first for the primitives; this file composes them.

## Execution discipline (read first)

Two rules apply to every pipeline below:

1. **Run the entire pipeline in one bash/exec tool call.** The blocks below are shown with one step per line for readability — when you actually run them, chain the steps with `&&` (or keep the `for` loops inline) inside a single tool invocation. Separate tool calls add latency and context overhead; a single `&&`-chained call also aborts cleanly on the first failing step.
2. **Sleep between high-level steps, not inside them.** kagete already paces the micro-events inside each command. But after a step that triggers UI transition (menu opens, modal appears, network request returns), add a short sleep before the next `find` / `screenshot` / `click` so you read the new state, not the old one. Rules of thumb: `0.2 s` after a context menu or submenu opens, `0.3–0.5 s` after a modal or view swap, and `sleep 0.25` inside poll loops for network-bound waits. Without sleep, `find` can return the pre-transition tree and you end up acting on stale paths.

Every pipeline here follows both rules.

---

## Pipeline 1 — Search in a List, Open the First Result

The canonical "open app → search for X → act on the result" flow. Works for Finder (find in folder), Mail (search mailbox), Spotify, iTunes/Music, Photos, any search-box-plus-results app.

```bash
APP="Mail"

# 1. Locate the search box
SEARCH=$(kagete find --app "$APP" --role AXTextField --title-contains "Search" --paths-only | head -1)

# 2. Focus it, clear anything that's there, type the query
kagete click --app "$APP" --ax-path "$SEARCH"
kagete key   --app "$APP" cmd+a
kagete key   --app "$APP" delete
kagete type  --app "$APP" "invoice 2026"
kagete key   --app "$APP" return

# 3. Wait for results to populate, then click the first one
for i in {1..12}; do
  HIT=$(kagete find --app "$APP" --role AXRow --paths-only 2>/dev/null | head -1)
  [ -n "$HIT" ] && break
  sleep 0.25
done
kagete click --app "$APP" --ax-path "$HIT" --count 2   # double-click to open
```

**Variant — visual-path when the results are custom-drawn:**

```bash
# After `kagete key … return`, screenshot the results pane
kagete screenshot --app "$APP" -o /tmp/r.png --crop "250,150,800,400" --grid-pitch 100

# Read the first row's approximate center off the grid labels, then
kagete click --x 450 --y 340 --count 2

# The next screenshot shows a pink crosshair at the landing spot.
# If it's above or below the target row, adjust y by the row height and retry.
kagete screenshot --app "$APP" -o /tmp/r-after.png --crop "250,150,800,400"
```

---

## Pipeline 2 — Fill a Multi-Field Form

Login windows, preference panes, new-record dialogs.

```bash
APP="Notes"

# 1. Click the first field to focus it
NAME=$(kagete find --app "$APP" --role AXTextField --title-contains "Name" --paths-only | head -1)
kagete click --app "$APP" --ax-path "$NAME"

# 2. Type, tab to next, type, repeat
kagete type --app "$APP" "Leader"
kagete key  --app "$APP" tab
kagete type --app "$APP" "leader@example.com"
kagete key  --app "$APP" tab
kagete type --app "$APP" "********"

# 3. Submit via Enter or explicit button click
kagete key --app "$APP" return
```

**Why tab over clicking each field:** Tab-order traversal works even when individual field paths change between renders. Clicking each needs a fresh `find`.

---

## Pipeline 3 — Replace Text in a Field

`kagete type` appends; it doesn't clear. To replace:

```bash
FIELD=$(kagete find --app Safari --role AXTextField --id "UnifiedAddress" --paths-only | head -1)

kagete click --app Safari --ax-path "$FIELD"
kagete key   --app Safari cmd+a      # select all
kagete key   --app Safari delete     # clear
kagete type  --app Safari "https://github.com"
kagete key   --app Safari return
```

Drop-in sequence — safe to use anywhere you need to overwrite a field's value.

---

## Pipeline 4 — Visual Path End-to-End (Custom-Drawn App)

When `find` returns `[]` for text you can clearly see, the app is rendering without exposing the AX tree. Switch to coordinates off the grid overlay.

```bash
APP="SomeCustomApp"

# 1. Focus the app
kagete raise --app "$APP"

# 2. If the search bar IS AX-indexed, use it; otherwise snapshot and pick coords
SEARCH=$(kagete find --app "$APP" --description-contains "Search" --paths-only | head -1)
if [ -n "$SEARCH" ]; then
  kagete click --app "$APP" --ax-path "$SEARCH"
else
  kagete screenshot --app "$APP" -o /tmp/s1.png   # full window, default grid
  # Read grid label under the visible search bar, then:
  kagete click --x 694 --y 95
fi

# 3. Clear + type + submit
kagete key  --app "$APP" cmd+a
kagete key  --app "$APP" delete
kagete type --app "$APP" "Jane Doe"
kagete key  --app "$APP" return
sleep 2     # wait for results render

# 4. Screenshot a tight crop of the results area, read a row's coords
kagete screenshot --app "$APP" -o /tmp/s2.png --crop "250,200,800,500" --grid-pitch 100

# 5. Click the row; next screenshot confirms the crosshair landed on it
kagete click --x 450 --y 340 --count 2
kagete screenshot --app "$APP" -o /tmp/s3.png --crop "250,200,800,500"
```

**Self-correct loop:** If the post-click screenshot's pink crosshair is above the intended row, add roughly one row-height (~40–60 points) to y and re-click. The corner badge shows the exact cursor coord.

---

## Pipeline 5 — Menu Item via Shortcut, with AX Fallback

Always try the shortcut first — it's one command and survives UI redesigns.

```bash
APP="TextEdit"

# Happy path — keyboard shortcut
kagete key --app "$APP" cmd+shift+s

# Fallback — no shortcut / shortcut unknown: walk AXMenuBar
MENU=$(kagete find --app "$APP" --role AXMenuBarItem --title "File" --paths-only | head -1)
kagete click --app "$APP" --ax-path "$MENU"
sleep 0.2

ITEM=$(kagete find --app "$APP" --role AXMenuItem --title "Duplicate" --paths-only | head -1)
kagete click --app "$APP" --ax-path "$ITEM"
```

---

## Pipeline 6 — Wait for a Modal, Dismiss It

Common after destructive or network actions.

```bash
APP="Foo"

# Trigger the action
kagete key --app "$APP" cmd+shift+delete

# Poll for the modal's button
for i in {1..24}; do
  OK=$(kagete find --app "$APP" --role AXButton --title "OK" --paths-only 2>/dev/null | head -1)
  if [ -n "$OK" ]; then
    kagete click --app "$APP" --ax-path "$OK"
    break
  fi
  sleep 0.25
done
```

Up to 6 seconds total — adjust the loop bound for slow confirmations (network saves, system dialogs).

---

## Pipeline 7 — Scroll Until an Element Becomes Visible

AX can see offscreen elements by frame, but clicks only land on what the window is actually rendering. Scroll the container, then re-locate.

```bash
APP="Finder"

for i in {1..20}; do
  HIT=$(kagete find --app "$APP" --title-contains "quarterly-report" --paths-only 2>/dev/null | head -1)
  if [ -n "$HIT" ]; then
    # Sanity-check frame is on-screen before clicking
    ON_SCREEN=$(kagete find --app "$APP" --title-contains "quarterly-report" --enabled-only 2>/dev/null \
                | jq -r '.result.hits[0].frame | (.y > 0 and .y < 1200)')
    if [ "$ON_SCREEN" = "true" ]; then
      kagete click --app "$APP" --ax-path "$HIT" --count 2
      break
    fi
  fi
  kagete scroll --app "$APP" --dy -5   # scroll down
  sleep 0.2
done
```

---

## Pipeline 8 — Right-Click Context Menu, Pick an Item

```bash
APP="Finder"

ROW=$(kagete find --app "$APP" --role AXRow --title-contains "Report.pdf" --paths-only | head -1)

# Open the context menu
kagete click --app "$APP" --ax-path "$ROW" --button right

# The menu is a separate top-level AX element; give it a beat to render
sleep 0.2

# Pick an item by title (menus expose AXMenuItem)
ITEM=$(kagete find --app "$APP" --role AXMenuItem --title "Get Info" --paths-only | head -1)
kagete click --app "$APP" --ax-path "$ITEM"
```

---

## Adapting These

Each pipeline is a template. To adapt:

1. Swap `APP`, filter strings, and target titles.
2. If a `find` comes back empty, try other filters (`--value-contains`, `--description-contains`) before falling back to Visual.
3. Bump the `sleep` count for slow apps (first-run, cold cache, network fetches).
4. Always end with a `find` or `screenshot` verification — trust but confirm.
