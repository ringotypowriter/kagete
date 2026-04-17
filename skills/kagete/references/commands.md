# kagete — Full Command Reference

Every subcommand emits a JSON envelope on stdout — `{ok, command, target?, result?, verify?, hint?, error?}` — unless noted (`--text` / `--paths-only` opt-outs). Errors also emit a short human line on stderr with a non-zero exit code. Target-selector flags (`--app`, `--bundle`, `--pid`, `--window`) are shared across all commands that operate on a specific app — see [../SKILL.md](../SKILL.md) for the selection rules and the full envelope + error-code vocabulary.

---

## `kagete doctor`

Check Accessibility + Screen Recording permissions.

```bash
kagete doctor                # JSON envelope, exit 1 if anything missing
kagete doctor --text         # human-readable report
kagete doctor --prompt       # also trigger system permission prompts
```

`result` shape: `{accessibility, screenRecording, allGranted}`. When missing grants exist, `hint` names them.

---

## `kagete windows`

Enumerate on-screen windows (`CGWindowList`). Fast, doesn't require AX.

```bash
kagete windows                       # all normal-layer windows
kagete windows --app Safari          # filter by app name
kagete windows --bundle com.apple.TextEdit
kagete windows --pid 12345
```

`result` shape: `{count, windows: [...]}`. Each window record contains: `windowId`, `pid`, `app`, `bundleId`, `title`, `bounds`, `layer`, `onScreen`. `hint` fires when a filter was supplied but `count == 0` (likely minimized / hidden).

---

## `kagete inspect`

**Default: compact summary.** `--tree`: full AX tree dump.

```bash
kagete inspect --app TextEdit                    # summary
kagete inspect --app Safari --window "GitHub" --tree --max-depth 8
kagete inspect --bundle com.apple.finder --tree --full --with-actions
```

Flags:

- `--max-depth N` (default `12`) — cap recursion depth.
- `--tree` — emit the full AX node tree instead of the summary.
- `--full` — with `--tree`: skip pruning of unlabeled `AXUnknown` nodes.
- `--with-actions` — with `--tree`: include each node's AX actions (extra IPC per element, slow on large trees).
- Standard target flags: `--app` / `--bundle` / `--pid` / `--window`.

Default `result` shape (summary):

```json
{
  "window": { "title", "role", "frame" },
  "totalNodes": 847,
  "nodesWithContent": 213,
  "roleHistogram": { "AXButton": 12, "AXTextField": 3, ... },
  "actionableCount": 18,
  "actionableSample": [{ "axPath", "role", "title", "actions": [...] }],
  "focusedAxPath": null
}
```

`hint` nudges you toward `find` (most cases) or `inspect --tree` (large windows, debugging). With `--tree`, `result` is the raw AXNode tree with `children`, same shape as before.

**Prefer `find` over `inspect --tree` when you know what you're looking for.**

---

## `kagete find`

Filtered search over the AX tree.

```bash
kagete find --app TextEdit --role AXButton
kagete find --app Safari --role AXButton --title-contains "Save"
kagete find --app Foo --id submit-btn
kagete find --app TextEdit --role AXTextArea --paths-only      # plain text, bypass envelope
```

`result` shape: `{count, truncated, limit, disabledCount, hits: [AXHit]}`. Each hit: `role`, `subrole`, `title`, `value`, `description`, `identifier`, `enabled`, `focused`, `actions`, `frame`, `axPath`.

Filters (AND-ed, at least one required):

- `--role AXButton` · `--subrole AXCloseButton`
- `--title "Save"` · `--title-contains "Sav"` · `--id "submit-btn"`
- `--description-contains "…"` · `--value-contains "…"`
- `--enabled-only` / `--disabled-only`

Shaping:

- `--limit N` (default `50`). When hits hit the cap, `result.truncated: true` and `hint` tells you how to narrow.
- `--max-depth N` (default `64`).
- `--paths-only` — plain newline-separated `axPath` strings (bypasses envelope, for shell piping).

`hint` branches: no matches → broaden filters; truncated → narrow; single AXPress hit → pass its axPath to `click`; many disabled hits → add `--enabled-only`.

---

## `kagete screenshot`

Capture a PNG of a window via ScreenCaptureKit with an absolute-coordinate grid overlay (red lines every 200 screen points, labeled with click-compatible `x=…`/`y=…` values).

```bash
kagete screenshot --app TextEdit -o /tmp/shot.png
kagete screenshot --bundle com.apple.Safari --window "GitHub" -o gh.png --scale 1
kagete screenshot --app Foo -o /tmp/clean.png --clean
kagete screenshot --app Foo -o /tmp/s.png --text          # prints only the path
```

Flags:

- `-o, --output PATH` (required) — destination PNG path.
- `--clean` — skip the grid overlay.
- `--grid-pitch N` (default `200`) — grid spacing in screen points.
- `--scale N` (default `0.5`) — output pixel scale relative to screen points; `1` = native, `2` = retina.
- `--crop "x,y,w,h"` — window-relative region in screen points; labels still show absolute coords.
- `--text` — print only the output path (shell-friendly) instead of the envelope.
- Standard target flags.

`result` shape: `{path, scale, grid, cropped}`. Errors: `SCK_TIMEOUT` (retryable) when ScreenCaptureKit hangs — wrapper times out at 15 s instead of wedging forever.

---

## `kagete click`

Click at an `axPath` (preferred) or absolute coordinates.

```bash
kagete click --app TextEdit --ax-path '/AXWindow[id="_NS:34"]/AXScrollArea/AXTextArea'
kagete click --x 640 --y 480
kagete click --app Safari --ax-path '…' --button right
kagete click --x 100 --y 200 --count 2                       # double-click
kagete click --x 100 --y 100 --text                          # one-line summary
```

Flags:

- `--ax-path STRING` — resolve via AX tree, click frame center.
- `--x DOUBLE` / `--y DOUBLE` — absolute screen point.
- `--button left|right|middle` (default `left`).
- `--count N` (default `1`) — `2` for double-click, `3` triple.
- `--activate` / `--no-activate` (default activate).
- `--no-ax-press` — force CGEvent click even when the element advertises `AXPress`.
- `--text` — one-line summary instead of the envelope.

`result` shape: `{method, button, count, point, element?}` where `method` is `ax-press`, `cg-event`, or `cg-event-fallback`. `element` (AX clicks only): `{axPath, role, title, actions}`.

`verify` shape: `{focusedAxPath?, focusedRole, focusedTitle, cursor}` — post-click focused element + cursor landing. Branch on this to confirm the click did what you expected.

`hint` fires on `cg-event-fallback` (AXPress accepted but UI didn't respond) and on AXPress with no observed focus change.

**Dispatch strategy.** For a plain left single-click on a resolved `--ax-path`, kagete prefers `AXUIElementPerformAction(AXPress)` when the element's `actions` list contains it. This routes through the accessibility API and works on occluded or offscreen elements. Multi-click, right-click, and coord-only clicks always use CGEvent.

---

## `kagete type`

Type a Unicode string into whatever element is currently focused. Use after `click`ing a text field.

```bash
kagete type --app TextEdit "Hello 🌍 中文"
kagete type --app Notes "Meeting: $(date)"
```

Flags:

- `<text>` (positional, required).
- Standard target flags (optional; if provided, app is activated first).
- `--activate` / `--no-activate`.

`result` shape: `{length}`. `verify` returns the focused element post-type; `hint` fires when no element was focused (text likely went nowhere useful).

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
  - Modifier aliases: `cmd`/`command`/`meta`, `ctrl`/`control`, `opt`/`option`/`alt`, `shift`, `fn`.
  - Named keys: `return`/`enter`, `tab`, `space`, `esc`/`escape`, `delete`/`backspace`, `forward-delete`, `home`, `end`, `pageup`, `pagedown`, `up`/`down`/`left`/`right`, `f1`-`f12`.
- Standard target flags (optional).
- `--activate` / `--no-activate`.

`result` shape: `{combo, keyCode}`. `verify.focusedRole/Title` shows where the combo was delivered. Errors: `INVALID_ARGUMENT` for unknown modifiers, multiple base keys, or empty combos.

---

## `kagete scroll`

Scroll the wheel at the current cursor position.

```bash
kagete scroll --dy -5                      # scroll down 5 lines
kagete scroll --dy 10 --app Safari         # scroll up in Safari
kagete scroll --dx 3 --dy 0 --pixels       # horizontal pixel scroll
```

Flags:

- `--dx INT` (default `0`) — horizontal ticks.
- `--dy INT` (default `0`) — vertical ticks.
- `--pixels` — use pixel units instead of line units.
- Standard target flags.
- `--activate` / `--no-activate`.

`result` shape: `{dx, dy, units}` where `units` is `"lines"` or `"pixels"`.

---

## `kagete drag`

Press, move, release. Interpolates intermediate motion so gesture recognizers register it as a real drag.

```bash
kagete drag --app TextEdit --from-x 100 --from-y 130 --to-x 400 --to-y 130
kagete drag --app Finder \
  --from-ax-path '/AXWindow/AXOutline/AXRow[0]' \
  --to-ax-path   '/AXWindow/AXOutline/AXRow[3]'
kagete drag --app Foo --from-x 100 --from-y 200 --to-x 300 --to-y 400 --mod shift
kagete drag --app Finder --from-ax-path '…' --to-ax-path '…' --hold-ms 250
```

Flags:

- `--from-x` / `--from-y` / `--to-x` / `--to-y` — absolute screen points.
- `--from-ax-path` / `--to-ax-path` — AX elements (their frame centers).
- `--steps N` (default `20`) — interpolation steps.
- `--hold-ms MS` (default `0`) — press-and-hold before starting motion.
- `--mod "shift+cmd"` — modifier flags held during drag.
- Standard target flags.
- `--activate` / `--no-activate`.

`result` shape: `{from, to, steps, holdMs, modifiers}`. `verify.cursor` confirms where the drag released.

---

## `kagete raise`

Raise a target window via the AX API — bypasses the activation broker that sometimes contests focus with tools like CleanShot X.

```bash
kagete raise --app TextEdit
kagete raise --bundle com.apple.finder --text
```

Flags:

- Standard target flags.
- `--text` — human-readable report instead of the envelope.

`result` shape: `{setFrontmost, raisedWindow, setMain, frontmostAfter, changedFocus}`. `hint` fires when `changedFocus == false` (another app holding focus).

---

## `kagete release`

Tell the awareness overlay daemon that the agent is done — shows a `✓ control returned` ceremony and retires the overlay.

```bash
kagete release
kagete release "handed back to user"
```

`result` shape: `{label}`. Always succeeds (fire-and-forget to the daemon socket).
