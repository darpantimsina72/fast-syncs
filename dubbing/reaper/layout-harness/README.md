# Layout harness

Loads `Dub_Pipeline_Panel.lua` and `auto_sync_pipeline.lua` and **actually draws
them** — no REAPER, no ReaImGui — to assert that nothing is ever drawn on top of
anything else.

```bash
npm install
node run.js          # the dub panel, 3 widths per case
WIDE=1 node run.js   # the dub panel, 11 widths from 1400 down to 220
node run-sync.js     # the Sync tab chunk
```

## What it is

`mock.lua` is a coarse Dear ImGui layout model in Lua: a window stack, an eager
cursor (ImGui's `ItemSize` advances `CursorPos.y` immediately and `SameLine`
walks *back*), `BeginChild` semantics where size 0 means "fill the remaining
parent size", and a rectangle recorded for every item and every
`DrawList_AddText`. A rectangle that lands on one already recorded is a
**collision**, which is the failure this exists to catch.

It runs under [fengari](https://fengari.io) (Lua in JS) because there is no Lua
interpreter on the dev machine. `run.js` splices `hooks.lua` into the panel
chunk so the tests can reach its file-level locals — the phase renderers and the
whole config state are `local`, so setting a same-named global is silently
ignored.

## The two standards

- **Collisions are never acceptable**, at any width. Overprinted text is
  unreadable, and it is what every one of the v0.26 defects produced.
- **Clipping is a failure at or above 560 px** — the panel's design floor
  (138 px rail + a usable form + the 288 px run column). Below that the panel
  degrades; it still must not overprint.

## Three measurement regimes

ReaImGui rasterizes glyphs on demand, so `ImGui_CalcTextSize` answers `0` for a
script its atlas has not baked yet. Every case is drawn three times:

| regime | `CalcTextSize` answers |
| --- | --- |
| `honest` | the real width |
| `nonascii0` | `0` for any string with a non-ASCII character |
| `all0` | `0` for everything |

The middle one is not hypothetical — it is every Indic label on the frame its
font was attached, and it is what the v0.26 defects needed to reproduce.

## What it checks beyond geometry

Collisions and clipping are the point, but the same load-and-draw gives a few
assertions that a parse cannot make:

- **Style stacks balance.** Push/PopStyleColor, Push/PopStyleVar and the font
  stack must all return to zero per draw, and `V5.form_begin` must be closed.
  A leak never breaks the pane that caused it — it breaks whatever draws next.
- **`V5.COL` keys exist.** A metatable raises on an unknown role during the
  draw, instead of passing nil to `PushStyleColor` where it sails through.
- **The screens' button bodies resolve.** Every button calls chunk-level
  locals; a typo there is a nil global, which is valid Lua until the day someone
  presses that button. `__H.callables()` hands them out and the test asserts
  their types.

## Traps worth knowing before you edit the mock

- `io.open` must be a **function returning nil**, not nil: the panel calls it
  unguarded at load time to read `VERSION`.
- The flag getters are `ImGui_WindowFlags_*`, `ImGui_TableFlags_*` — there is
  **no underscore before `Flags`**. Matching `'_Flags_'` makes every
  `f | reaper.ImGui_WindowFlags_NoScrollbar()` die on nil.
- `ImGui_DrawList_*` takes the **draw list** as argument 1, not the ctx.
- `GetCursorScreenPos` and `GetContentRegionAvail` each return **two** values.
- A `BeginCombo` list lives in its own popup window, so the closed state is the
  one to model — returning `true` draws every `Selectable` inline and reports
  overflow that does not exist.
- Don't range-check colours: fengari's integers wrap at 32 bits, so
  `0xC8CDD3FF` reads back negative. Type-check for nil instead.
- `0` is a **truthy** Lua value but means "use the default" to ImGui, so
  `h or FRAME_H` keeps the zero — that silently gave every `Button(l, w, 0)` no
  height and removed whole chip rows from the model.
- A `SameLine`d child is still an *item*: it joins the current line, the cursor
  drops past the tallest thing on that line, and the line height is then
  **cleared**. Leaving it set made a second column-height child push whatever
  followed one full column too low.
- Model `TableSetupColumn` widths and **clip cell content to the cell** — Dear
  ImGui does. Uniform columns plus unclipped cells invents collisions the table
  cannot produce on screen.
- `T.files[path] = contents` makes exactly that path readable through `io.open`
  (reads only — every write still answers nil). The review screen recovers its
  paragraph timings from the run's English SRT, so its test needs one real file.
- An `InvisibleButton` is a hit target, not visible content: the plan strip draws
  its whole ruler on top of one, so it must not collide.
