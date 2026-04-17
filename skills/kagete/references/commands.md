# kagete — Full Command Reference

Every subcommand emits JSON to stdout (unless noted) and human-readable errors to stderr with a non-zero exit code. Target-selector flags (`--app`, `--bundle`, `--pid`, `--window`) are shared across all commands that operate on a specific app — see [../SKILL.md](../SKILL.md) for the selection rules.

---

## `kagete doctor`

Check Accessibility + Screen Recording permissions.

```bash
kagete doctor                # human-readable text, exit 1 if anything missing
kagete doctor --json         # JSON: {accessibility, screenRecording, ok}
kagete doctor --prompt       # also trigger system permission prompts
```

---

## `kagete windows`

Enumerate on-screen windows (`CGWindowList`). Fast, doesn't require AX.

```bash
kagete windows                       # all normal-layer windows
kagete windows --app Safari          # filter by app name
kagete windows --bundle com.apple.TextEdit
kagete windows --pid 12345
```

Each record contains: `windowId`, `pid`, `app`, `bundleId`, `title`, `bounds`, `layer`, `onScreen`.

---

## `kagete inspect`

Dump the AX element tree of a single window as nested JSON.

```bash
kagete inspect --app TextEdit
kagete inspect --app Safari --window "GitHub" --max-depth 8
kagete inspect --bundle com.apple.finder --max-depth 4
```

Flags:

- `--max-depth N` (default `12`) — cap recursion depth. Useful for huge windows.
- `--full` — emit the raw tree without pruning. Default is compact: unlabeled `AXUnknown` nodes with no labeled descendants are dropped. The surviving nodes keep their original `axPath`, so `find`/`click` still resolve against the live tree.
- `--with-actions` — include each node's advertised AX actions (e.g. `AXPress`). Adds one IPC call per node — avoid on large web-embedded UIs (Tencent apps, Electron).
- Standard target flags: `--app` / `--bundle` / `--pid` / `--window`.

Each node has: `role`, `subrole`, `title`, `value`, `description`, `identifier`, `help`, `enabled`, `focused`, `actions`, `frame`, `axPath`, `children`.

**Prefer `find` instead when you know what you're looking for.**

---

## `kagete find`

Filtered search over the AX tree. Returns flat JSON hits or raw paths.

```bash
# All buttons in TextEdit
kagete find --app TextEdit --role AXButton

# Save button specifically
kagete find --app Safari --role AXButton --title-contains "Save"

# Elements with identifier "submit-btn"
kagete find --app Foo --id submit-btn

# Just paths, one per line — shell-pipeline-friendly
kagete find --app TextEdit --role AXTextArea --paths-only
```

Filters (AND-ed, at least one required):

- `--role AXButton` — exact AX role
- `--subrole AXCloseButton` — exact AX subrole
- `--title "Save"` — exact title match
- `--title-contains "Sav"` — case-insensitive substring
- `--id "submit-btn"` — exact AXIdentifier
- `--description-contains "…"`
- `--value-contains "…"`
- `--enabled-only` / `--disabled-only`

Shaping flags:

- `--limit N` (default `50`) — cap results
- `--max-depth N` (default `64`) — traversal depth cap
- `--paths-only` — emit newline-separated axPath strings instead of JSON

---

## `kagete screenshot`

Capture a PNG of a window via ScreenCaptureKit (retina-correct).

```bash
kagete screenshot --app TextEdit -o /tmp/shot.png
kagete screenshot --bundle com.apple.Safari --window "GitHub" -o gh.png
```

Flags:

- `-o, --output PATH` (required) — destination PNG path
- Standard target flags.

Prints the resolved absolute path on success.

---

## `kagete click`

Click at an `axPath` (preferred) or absolute coordinates.

```bash
# By axPath — most stable
kagete click --app TextEdit --ax-path '/AXWindow[id="_NS:34"]/AXScrollArea[id="_NS:8"]/AXTextArea[id="First Text View"]'

# By coords — fallback
kagete click --x 640 --y 480

# Right-click, double-click
kagete click --app Safari --ax-path '…' --button right
kagete click --x 100 --y 200 --count 2
```

Flags:

- `--ax-path STRING` — resolve via AX tree, click frame center
- `--x DOUBLE` / `--y DOUBLE` — absolute screen point
- `--button left|right|middle` (default `left`)
- `--count N` (default `1`) — `2` for double-click, `3` triple
- `--activate` / `--no-activate` (default activate) — bring target app frontmost first
- `--no-ax-press` — force CGEvent click even when the element advertises `AXPress`
- `--json` — print a dispatch report (`{method, point, actions, axPath}`)

**Dispatch strategy.** For a plain left single-click on a resolved `--ax-path`, kagete prefers `AXUIElementPerformAction(AXPress)` when the element's `actions` list contains it. This routes through the accessibility API and works on occluded or offscreen elements. Multi-click, right-click, and coord-only clicks always use CGEvent.

---

## `kagete type`

Type a Unicode string into whatever element is currently focused. Use after `click`ing a text field.

```bash
kagete type --app TextEdit "Hello 🌍 中文"
kagete type --app Notes "Meeting: $(date)"
```

Flags:

- `<text>` (positional, required)
- Standard target flags (optional; if provided, app is activated first)
- `--activate` / `--no-activate` (default activate)

Note: `type` emits key events — it doesn't clear the field. Use `kagete key cmd+a` followed by `kagete key delete` to clear first if needed.

---

## `kagete key`

Send a key combo to the focused element.

```bash
kagete key --app Safari cmd+t             # new tab
kagete key --app TextEdit cmd+s           # save
kagete key --app Foo shift+tab
kagete key --app Bar return
kagete key f12
```

Flags:

- `<combo>` (positional, required) — `cmd+shift+s`, `return`, `f1`..`f12`, arrows, etc.
  - Modifier aliases: `cmd`/`command`/`meta`, `ctrl`/`control`, `opt`/`option`/`alt`, `shift`, `fn`
  - Named keys: `return`/`enter`, `tab`, `space`, `esc`/`escape`, `delete`/`backspace`, `forward-delete`, `home`, `end`, `pageup`, `pagedown`, `up`/`down`/`left`/`right`, `f1`-`f12`
- Standard target flags (optional)
- `--activate` / `--no-activate`

---

## `kagete scroll`

Scroll the wheel at the current cursor position.

```bash
kagete scroll --dy -5                      # scroll down 5 lines
kagete scroll --dy 10 --app Safari         # scroll up in Safari
kagete scroll --dx 3 --dy 0 --pixels       # horizontal pixel scroll
```

Flags:

- `--dx INT` (default `0`) — horizontal ticks (positive = right)
- `--dy INT` (default `0`) — vertical ticks (positive = up, negative = down)
- `--pixels` — use pixel units instead of line units
- Standard target flags
- `--activate` / `--no-activate`

---

## `kagete drag`

Press, move, release. Interpolates intermediate motion so gesture recognizers register it as a real drag.

```bash
# Select text by dragging across it
kagete drag --app TextEdit --from-x 100 --from-y 130 --to-x 400 --to-y 130

# Drag one AX element onto another
kagete drag --app Finder \
  --from-ax-path '/AXWindow/AXOutline/AXRow[0]' \
  --to-ax-path   '/AXWindow/AXOutline/AXRow[3]'

# Shift-drag to extend a selection
kagete drag --app Foo --from-x 100 --from-y 200 --to-x 300 --to-y 400 --mod shift

# Apps that need a press-and-hold before recognizing the drag (Finder icons, etc.)
kagete drag --app Finder --from-ax-path '…' --to-ax-path '…' --hold-ms 250
```

Flags:

- `--from-x` / `--from-y` / `--to-x` / `--to-y` — absolute screen points
- `--from-ax-path` / `--to-ax-path` — AX elements (their frame centers)
- `--steps N` (default `20`) — interpolation steps
- `--hold-ms MS` (default `0`) — press-and-hold before starting motion
- `--mod "shift+cmd"` — modifier flags held during drag
- Standard target flags
- `--activate` / `--no-activate`
