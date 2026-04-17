# Verify Loop — Closing the Feedback Loop

Blind action is brittle. After every state-changing kagete call, **verify it had the effect you expected** before taking the next step. This is the single biggest reliability lever for GUI automation.

## Two Verification Modes

### 1. Structural — re-query with `find`

Fast, machine-readable, works for changes that affect the AX tree (a button appears/disappears, a value updates, a modal opens).

```bash
# Before: save button is enabled
kagete find --app TextEdit --role AXButton --title "Save" | jq '.result.hits[0].enabled'
# true

# Act
kagete key --app TextEdit cmd+s

# After: document title lost the "— Edited" suffix (= save succeeded)
kagete find --app TextEdit --role AXWindow --title-contains "Edited" | jq '.result.count'
# 0 — verified
```

Many input commands carry the post-action state on the response envelope itself (`verify.focusedRole` for `type`/`key`, `verify.cursor` for `click`/`drag`), so you often don't need a follow-up `find` at all:

```bash
# After typing, confirm the focused element is the field you meant
kagete type --app TextEdit "hello" | jq -e '.verify.focusedRole == "AXTextField"'

# After clicking, confirm the cursor landed where you asked
kagete click --app TextEdit --x 800 --y 400 | jq -e '.verify.cursor.x == 800 and .verify.cursor.y == 400'
```

> Note: `click`'s verify reports `cursor` only — it does **not** report a focused role. App-level keyboard focus (`AXFocusedUIElement`) is unrelated to "what was clicked": buttons usually don't take focus, so reading focus after a click would surface whatever sidebar/list happened to hold focus before. To check what a click actually hit, re-`find` or screenshot.

### 2. Visual — screenshot and read it

For agents with vision (Claude Code, Claude.ai with image input), a screenshot is a cheap full-state snapshot. Use when the AX tree doesn't expose what you need (canvas renders, custom-drawn UI, visual-only cues like highlight state).

```bash
kagete screenshot --app TextEdit -o /tmp/after.png
# Then Read /tmp/after.png — the agent can see the result directly
```

**Tip for Claude Code:** pass the PNG path to the Read tool. Claude sees the image inline in the conversation.

---

## The Closed-Loop Pattern

```
┌──────────────┐
│  screenshot  │  (baseline, optional)
└──────┬───────┘
       ▼
┌──────────────┐
│     find     │  (get axPath)
└──────┬───────┘
       ▼
┌──────────────┐
│   click /    │  (act)
│   type / …   │
└──────┬───────┘
       ▼
┌──────────────┐
│  screenshot  │  (after)
│   or find    │
└──────┬───────┘
       ▼
  compare & decide next step
```

---

## Recipe — Screenshot Before/After

```bash
# Baseline
kagete screenshot --app Safari -o /tmp/before.png

# Act
kagete click --app Safari --ax-path '/AXWindow/AXToolbar/AXButton[title="Reload"]'
sleep 1            # app-side network work — not a kagete pacing need

# Capture result
kagete screenshot --app Safari -o /tmp/after.png
```

Then read both images (Claude Code `Read` tool, or whatever your vision layer is) and decide if the outcome matches intent.

---

## Recipe — Structural Diff with `find`

```bash
# Before
before=$(kagete find --app Foo --role AXRow --paths-only | wc -l)

# Act: click a button that should add a row
kagete click --app Foo --ax-path '…'

# After
after=$(kagete find --app Foo --role AXRow --paths-only | wc -l)

if [ "$after" -gt "$before" ]; then
  echo "row added OK"
else
  echo "action did not produce expected row"
fi
```

---

## Recipe — Confirm Focus Landed Before Typing

`type` and `key` envelopes report `verify.focusedRole` — their action goes to the focused element, so the field is meaningful. (`click`'s verify reports `cursor` only — see the note above.) Pattern: type a single character (or your real payload) and branch on the focused role:

```bash
kagete click --app Mail --ax-path '…/AXTextField[title="To:"]'

role=$(kagete type --app Mail "leader@example.com" | jq -r '.verify.focusedRole')
if [ "$role" != "AXTextField" ]; then
  echo "focus didn't land where expected — text may have gone to the wrong field"
  exit 1
fi
```

---

## Recipe — Wait Until an Expected Element Exists

Useful after clicks that open modals or load content:

```bash
# Click something that opens a dialog
kagete click --app Foo --ax-path '…'

# Poll for the dialog's Confirm button
for i in {1..20}; do
  if kagete find --app Foo --role AXButton --title "Confirm" --paths-only | grep -q .; then
    break
  fi
  sleep 0.25
done

# Now safe to interact with the dialog
```

---

## When to Use Which

| Situation | Use |
|---|---|
| Did my click land on the right point? | Read `.verify.cursor` on the click envelope. To verify the click *target* (not just the point), re-`find`/`screenshot`/`inspect` after. |
| Did the value in this field update? | `find` → `.result.hits[0].value` |
| Did a dialog appear? | `find --role AXSheet` / `AXDialog` / `--title "…"` |
| Did the page's visual state change? | `screenshot`, then Read |
| Was a visual-only element (chart, canvas, custom view) updated? | `screenshot` |
| Is a long-running op done? | Poll `find` for a "loading" indicator to disappear |

---

## Common Verification Mistakes

- **Verifying too late.** Verify between every action, not at the end of a 10-step chain — when something breaks you want to know which step failed.
- **Only screenshotting.** Screenshots are expensive (ScreenCaptureKit capture + PNG encode). Prefer `find` when the AX tree exposes the signal.
- **Trusting exit codes alone.** `kagete click` returns 0 whenever the event was *posted*, not when it was *received*. The app may have swallowed it. Always verify downstream state.
- **Not re-finding paths.** An axPath you used 5 seconds ago may no longer resolve. Re-`find` before each new act.
