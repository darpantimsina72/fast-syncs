"""
Self-contained HTML review page for a sync plan (contract v0.13; editable
since v0.15).

NEW module. The REAPER panel cannot show this: Dear ImGui has no complex-text
shaping, so Devanagari and every other Indic script renders with broken
conjuncts there (documented as a cosmetic limit since v0.4). A review whose
entire point is reading the target text next to its time slot therefore has
to leave the panel. The panel keeps the approval gate; this file is what you
actually read — and, since v0.15, what you correct in.

Editing here is free and instant: the target cells are contenteditable, and
every keystroke re-estimates that chunk with the same arithmetic the engine
uses (strip [tags], count characters, divide by the language's chars/sec),
so the fit bar, the verdict and the timeline bar move as you cut words. What
the page hands back is a complete plan file — the same format --steps plan
wrote — which the panel writes over the original and re-measures. The plan
file stays the one contract between the two surfaces.

The page cannot write to disk (it is opened as file://, with no server), so
"save" means Copy to clipboard or Download, and the panel pulls it in. That
is deliberate: no background writer can surprise a paid run with text nobody
looked at.

Output is ONE file with no external requests — inline CSS, inline JS, system
font stack. The repo is used on machines behind corporate TLS inspection and
sometimes offline; a CDN reference would render this blank exactly when it
matters.
"""

import html
import json
import os
from typing import Dict, Optional, Sequence

from .pausechunk import (PLAN_HEADER, PLAN_FORMAT_VERSION, SHORT_RATIO,
                         chars_per_sec, plan_counts)

# Verdict → (label, bar colour, text colour). Colours are chosen to stay
# distinguishable in both light and dark, and to survive greyscale printing
# by differing in lightness as well as hue.
_VERDICT_STYLE = {
    "fits":  ("fits",          "#2f9e44", "#ffffff"),
    "tight": ("eats pause",    "#e8a13a", "#3a2a00"),
    "over":  ("OVERFLOWS",     "#d94b3f", "#ffffff"),
    "short": ("short",         "#4a86c7", "#ffffff"),
    "empty": ("no text",       "#8a8a8a", "#ffffff"),
}
_VERDICT_ORDER = ("fits", "tight", "over", "short", "empty")

_DEFAULT_PX_PER_SEC = 60

_CSS = """
:root { --pxs: __PXS__; --bg:#ffffff; --fg:#1b1b1b; --muted:#6a6a6a;
        --line:#e0e0e0; --lane:#f4f4f5; --pause:#d8d8dc; --card:#fafafa;
        --field:#ffffff; --fieldline:#c9c9cf; --track:#e6e6e9; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#16171a; --fg:#e9e9ec; --muted:#9a9aa2; --line:#2c2d32;
          --lane:#1f2024; --pause:#34353c; --card:#1c1d21;
          --field:#111214; --fieldline:#34353c; --track:#0d0e10; }
}
* { box-sizing: border-box; }
body { margin:0; padding:24px; background:var(--bg); color:var(--fg);
       font:14px/1.5 -apple-system, "Segoe UI", Roboto, system-ui, sans-serif; }
.indic { font-family: "Nirmala UI", "Noto Sans Devanagari", "Noto Sans",
         "Kohinoor Devanagari", "Segoe UI", system-ui, sans-serif; }
h1 { font-size:20px; margin:0 0 4px; font-weight:650; }
.sub { color:var(--muted); font-size:13px; margin-bottom:18px; }
.counts { display:flex; flex-wrap:wrap; gap:8px; margin:0 0 16px; }
.pill { padding:4px 11px; border-radius:999px; font-size:12px;
        font-weight:600; color:#fff; }
.controls { display:flex; align-items:center; gap:10px; margin-bottom:10px;
            font-size:13px; color:var(--muted); flex-wrap:wrap; }
/* Fixed gutter + scrolling track. The lane labels sit OUTSIDE the scroller
   so they stay put while the timeline pans; their heights mirror the track's
   rows exactly (ruler 22, then 8 margin + 44 lane, twice). */
.tlwrap { display:flex; align-items:flex-start; }
.gutter { flex:0 0 74px; }
.gspacer { height:23px; }
.glabel { height:52px; padding-top:22px; font-size:10px;
          text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
.scroller { flex:1 1 auto; min-width:0; overflow-x:auto; overflow-y:hidden;
            border:1px solid var(--line); border-radius:8px;
            background:var(--card); }
.track { position:relative; height:126px; }
.ruler { position:relative; height:22px; border-bottom:1px solid var(--line); }
.tick { position:absolute; top:0; height:22px; border-left:1px solid var(--line);
        padding-left:4px; font-size:11px; color:var(--muted); white-space:nowrap; }
.lane { position:relative; height:44px; margin-top:8px; background:var(--lane);
        border-radius:4px; }
.bar { position:absolute; top:6px; height:32px; border-radius:4px;
       font-size:11px; line-height:32px; padding:0 6px; overflow:hidden;
       white-space:nowrap; text-overflow:ellipsis; cursor:pointer; }
.src { background:#5b6470; color:#fff; }
.bar.sel { outline:2px solid var(--fg); outline-offset:1px; }
.pausegap { position:absolute; top:14px; height:16px; border-radius:2px;
            background:repeating-linear-gradient(45deg, var(--pause) 0 4px,
            transparent 4px 8px); }

/* ── editable rows ──────────────────────────────────────────────────────── */
#rows { display:flex; flex-direction:column; gap:8px; margin-top:26px; }
.row { display:grid; grid-template-columns:82px 1fr 210px; gap:14px;
       align-items:start; padding:10px 12px; border:1px solid var(--line);
       border-radius:6px; background:var(--card); }
.row.hot { border-color:#d94b3f; background:rgba(217,75,63,.07); }
.row.sel { box-shadow:0 0 0 2px var(--fg) inset; }
.row.hidden { display:none; }
.t { font:11.5px/1.55 ui-monospace, "Cascadia Mono", Consolas, monospace;
     color:var(--muted); font-variant-numeric:tabular-nums; }
.t b { display:block; font-size:13px; color:var(--fg); }
.en { color:var(--muted); font-size:12.5px; margin-bottom:6px; }
.ed { background:var(--field); border:1px solid var(--fieldline);
      border-left:2px solid #4a86c7; border-radius:3px; padding:8px 10px;
      font-size:16px; line-height:1.55; white-space:pre-wrap;
      overflow-wrap:anywhere; color:var(--fg); }
.ed:focus { outline:2px solid #4a86c7; outline-offset:1px; }
.ed.edited { border-left-color:#e8a13a; }
.side { display:flex; flex-direction:column; gap:6px;
        font:11.5px/1.5 ui-monospace, "Cascadia Mono", Consolas, monospace;
        color:var(--muted); font-variant-numeric:tabular-nums; }
.side .v { font-weight:700; }
.meter { position:relative; height:10px; width:100%; border-radius:2px;
         background:var(--track); overflow:hidden; }
.meter .slot { position:absolute; top:0; bottom:0; left:0;
               background:var(--lane); }
.meter .pausez { position:absolute; top:0; bottom:0;
                 background:repeating-linear-gradient(45deg, var(--pause) 0 3px,
                 transparent 3px 6px); }
.meter .est { position:absolute; top:0; bottom:0; left:0; border-radius:2px; }
.meter .edge { position:absolute; top:0; bottom:0; width:1px;
               background:var(--fg); opacity:.55; }

/* ── save bar ───────────────────────────────────────────────────────────── */
.savebar { position:sticky; bottom:0; display:flex; align-items:center;
           gap:10px; flex-wrap:wrap; margin-top:22px; padding:11px 13px;
           border:1px solid var(--line); border-radius:6px;
           background:var(--card); font-size:12.5px; color:var(--muted); }
button { font:inherit; font-size:13px; padding:7px 14px; border-radius:4px;
         border:1px solid var(--fieldline); background:var(--card);
         color:var(--fg); cursor:pointer; }
button:hover { border-color:var(--fg); }
button.pri { background:#2f9e44; border-color:#27853a; color:#fff;
             font-weight:600; }
button.pri:hover { background:#37b350; }
button.on { background:#4a86c7; border-color:#4a86c7; color:#fff;
            font-weight:600; }
button:focus-visible { outline:2px solid #4a86c7; outline-offset:2px; }
.dirty { color:#e8a13a; font-weight:600; }
.foot { margin-top:22px; color:var(--muted); font-size:12px; }
@media (max-width: 760px) { .row { grid-template-columns:1fr; } }
"""

_JS = r"""
(function () {
  var D = window.__PLAN__;
  var rows = D.rows, RATE = D.rate, MAXA = D.max_atempo, SHORT = D.short_ratio;
  var state = rows.map(function (r) { return { tr: r.tr, dirty: false }; });
  var sel = -1, onlyBad = false;

  function collapse(s) { return (s || '').replace(/\s+/g, ' ').trim(); }

  // Same arithmetic as pausechunk.estimate_fit / config.estimate_duration:
  // strip [tags], count what is left, divide by the language rate.
  function measure(i) {
    var r = rows[i], text = collapse(state[i].tr);
    var clean = text.replace(/\[.*?\]/g, '').trim();
    var est = RATE ? clean.length / RATE : 0;
    var speech = Math.max(0, r.dur), hard = speech + Math.max(0, r.pause);
    var v;
    if (!clean) { est = 0; v = 'empty'; }
    else if (est > hard && hard > 0) v = 'over';
    else if (est > speech) v = 'tight';
    else if (speech > 0 && est < speech * SHORT) v = 'short';
    else v = 'fits';
    var atempo = 1.0, over = 0;
    if (v === 'over') { over = est - hard; atempo = Math.min(est / hard, MAXA); }
    return { text: text, chars: clean.length, est: est, verdict: v,
             atempo: atempo, over: over, speech: speech, hard: hard };
  }

  function fmtClock(s) {
    s = Math.max(0, s); var m = Math.floor(s / 60), r = s - m * 60;
    return m + ':' + (r < 10 ? '0' : '') + r.toFixed(2);
  }

  function advice(m) {
    if (m.verdict === 'over') {
      var cut = Math.ceil(m.over * RATE);
      return 'cut ~' + cut + ' chars, or ' + m.atempo.toFixed(2) + '×';
    }
    if (m.verdict === 'tight')
      return (m.est - m.speech).toFixed(2) + 's into the pause';
    if (m.verdict === 'short')
      return (m.speech - m.est).toFixed(2) + 's of dead air';
    if (m.verdict === 'empty') return 'nothing will be spoken here';
    return (m.hard - m.est).toFixed(2) + 's spare';
  }

  function paint(i) {
    var m = measure(i), st = D.style[m.verdict];
    var row = document.getElementById('row' + i);
    var ed  = document.getElementById('ed' + i);

    row.className = 'row' + (m.verdict === 'over' ? ' hot' : '')
                  + (i === sel ? ' sel' : '')
                  + (onlyBad && m.verdict === 'fits' ? ' hidden' : '');
    ed.classList.toggle('edited', state[i].dirty);

    document.getElementById('v' + i).textContent = st[0]
      + (m.verdict === 'over' ? ' +' + m.over.toFixed(2) + 's' : '');
    document.getElementById('v' + i).style.color = st[1];
    document.getElementById('n' + i).textContent =
      m.chars + ' chars · est ' + m.est.toFixed(2) + 's';
    document.getElementById('a' + i).textContent = advice(m);

    // Meter: slot track, hatched pause, estimate on top, notch where the
    // source speaker stopped. Scale so an overflow is always visible.
    var scale = Math.max(m.hard, m.est, 0.01);
    document.getElementById('ms' + i).style.width = (100 * m.speech / scale) + '%';
    var pz = document.getElementById('mp' + i);
    pz.style.left  = (100 * m.speech / scale) + '%';
    pz.style.width = (100 * (m.hard - m.speech) / scale) + '%';
    var me = document.getElementById('me' + i);
    me.style.width = (100 * m.est / scale) + '%';
    me.style.background = st[1];
    document.getElementById('mg' + i).style.left = (100 * m.speech / scale) + '%';

    // Timeline: the dub bar keeps its start and changes length + colour, so
    // a line that outgrows its source is visible up there too.
    var bar = document.getElementById('tb' + i);
    if (bar) {
      bar.style.width = 'calc(' + m.est.toFixed(3) + ' * var(--pxs) * 1px)';
      bar.style.background = st[1];
      bar.style.color = st[2];
      bar.textContent = m.text;
      bar.title = '#' + rows[i].index + '  ' + fmtClock(rows[i].start)
        + '  slot ' + m.speech.toFixed(2) + 's +' + rows[i].pause.toFixed(2)
        + 's pause · est ' + m.est.toFixed(2) + 's · ' + st[0];
      bar.style.display = m.est > 0 ? '' : 'none';
    }
    return m;
  }

  // Tallies only — no per-row DOM work, so a keystroke costs one repainted
  // row plus this, not a full redraw of a 500-chunk plan.
  function tally() {
    var counts = {}, dirty = 0, bad = 0;
    for (var i = 0; i < rows.length; i++) {
      var v = measure(i).verdict;
      counts[v] = (counts[v] || 0) + 1;
      if (state[i].dirty) dirty++;
      if (v !== 'fits') bad++;
    }
    var pills = '';
    for (var k = 0; k < D.order.length; k++) {
      var key = D.order[k], n = counts[key] || 0;
      if (!n) continue;
      var st = D.style[key];
      pills += '<span class="pill" style="background:' + st[1] + ';color:'
            + st[2] + '">' + n + ' ' + st[0] + '</span>';
    }
    document.getElementById('pills').innerHTML = pills;
    document.getElementById('badcount').textContent =
      'Only problems (' + bad + ')';
    var d = document.getElementById('dirty');
    d.textContent = dirty ? dirty + ' unsaved edit' + (dirty > 1 ? 's' : '')
                          : 'no edits yet';
    d.className = dirty ? 'dirty' : '';
  }

  function paintAll() {
    for (var i = 0; i < rows.length; i++) paint(i);
    tally();
  }

  function select(i) {
    sel = i;
    for (var j = 0; j < rows.length; j++) {
      var sb = document.getElementById('sb' + j), tb = document.getElementById('tb' + j);
      if (sb) sb.classList.toggle('sel', j === i);
      if (tb) tb.classList.toggle('sel', j === i);
      var rw = document.getElementById('row' + j);
      if (rw) rw.classList.toggle('sel', j === i);
    }
  }

  // ── the plan file this page hands back ──────────────────────────────────
  // Byte-for-byte the format --steps plan writes, so the panel can drop it
  // straight over the original. Verdict/est/atempo are recomputed here for
  // consistency; the engine ignores them and re-derives every timing from
  // the audio on reload.
  function planText() {
    var out = [D.header];
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i], m = measure(i);
      out.push('[' + r.index + '] [' + Math.round(r.start * 1000) + 'ms] ['
        + Math.round(r.end * 1000) + 'ms] [' + Math.round(r.dur * 1000)
        + 'ms] [' + Math.round(r.pause * 1000) + 'ms] [' + m.verdict + '] ['
        + Math.round(m.est * 1000) + 'ms] [' + m.atempo.toFixed(2) + ']');
      out.push('EN: ' + r.en);
      out.push('TR: ' + m.text);
      out.push('');
    }
    return out.join('\n');
  }

  function flash(msg, ok) {
    var el = document.getElementById('flash');
    el.textContent = msg;
    el.style.color = ok ? '#2f9e44' : '#d94b3f';
  }

  function copyPlan() {
    var text = planText();
    // file:// is not a secure context in Chromium, so navigator.clipboard is
    // usually undefined here — the textarea fallback is the real path.
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(
        function () { marksaved('Copied — paste it in the panel.'); },
        function () { legacyCopy(text); });
    } else { legacyCopy(text); }
  }

  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    if (ok) marksaved('Copied — paste it in the panel.');
    else flash('Could not reach the clipboard — use Download instead.', false);
  }

  function marksaved(msg) {
    for (var i = 0; i < state.length; i++) state[i].dirty = false;
    paintAll();
    flash(msg, true);
  }

  function downloadPlan() {
    var blob = new Blob([planText()], {type: 'text/plain;charset=utf-8'});
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = D.plan_name;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
    marksaved('Downloaded ' + D.plan_name + ' — replace the file in the run '
      + 'folder, then press Reload in the panel.');
  }

  // ── wiring ──────────────────────────────────────────────────────────────
  for (var i = 0; i < rows.length; i++) {
    (function (i) {
      var ed = document.getElementById('ed' + i);
      ed.addEventListener('input', function () {
        state[i].tr = ed.innerText;
        state[i].dirty = true;
        paint(i);
        tally();
      });
      ed.addEventListener('focus', function () { select(i); });
      // One chunk is one line. Enter moves on instead of splitting the text
      // into a continuation line nobody asked for.
      ed.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          var nxt = document.getElementById('ed' + (i + 1));
          if (nxt) { nxt.focus(); nxt.scrollIntoView({block: 'center'}); }
        }
      });
      // contenteditable pastes markup by default; this page only carries text.
      ed.addEventListener('paste', function (e) {
        e.preventDefault();
        var t = (e.clipboardData || window.clipboardData).getData('text');
        document.execCommand('insertText', false, collapse(t));
      });
      var sb = document.getElementById('sb' + i), tb = document.getElementById('tb' + i);
      var jump = function () {
        select(i);
        var row = document.getElementById('row' + i);
        // Clicking a bar must always land you on its row, so a "only
        // problems" filter that would hide it steps aside instead.
        if (row.classList.contains('hidden')) {
          onlyBad = false;
          document.getElementById('badcount').classList.remove('on');
          paintAll();
        }
        row.scrollIntoView({block: 'center'});
        document.getElementById('ed' + i).focus();
      };
      if (sb) sb.addEventListener('click', jump);
      if (tb) tb.addEventListener('click', jump);
    })(i);
  }

  document.getElementById('badcount').addEventListener('click', function () {
    onlyBad = !onlyBad;
    this.classList.toggle('on', onlyBad);
    paintAll();
  });
  document.getElementById('copy').addEventListener('click', copyPlan);
  document.getElementById('dl').addEventListener('click', downloadPlan);

  var z = document.getElementById('zoom');
  if (z) {
    z.addEventListener('input', function () {
      document.documentElement.style.setProperty('--pxs', z.value);
      document.getElementById('zoomval').textContent = z.value + ' px/s';
    });
  }

  window.addEventListener('beforeunload', function (e) {
    for (var i = 0; i < state.length; i++) {
      if (state[i].dirty) { e.preventDefault(); e.returnValue = ''; return; }
    }
  });

  paintAll();
})();
"""


def _esc(t: str) -> str:
    return html.escape(t or "", quote=True)


def _clock(seconds: float) -> str:
    s = max(0.0, float(seconds))
    m, rem = divmod(s, 60.0)
    return f"{int(m):d}:{rem:05.2f}"


def _ruler_step(total_s: float) -> int:
    for step in (1, 2, 5, 10, 15, 30, 60, 120, 300):
        if total_s / step <= 40:
            return step
    return 600


def render_plan_html(plan: Sequence[Dict], out_path: str,
                     audio_path: str = "", language: str = "",
                     total_dur_s: float = 0.0,
                     max_atempo: float = 1.25,
                     rate_override: float = 0.0,
                     px_per_sec: int = _DEFAULT_PX_PER_SEC) -> str:
    """Write the editable review page for *plan* to *out_path*; return the path.

    Two lanes on one shared time axis: the source speech above, the estimated
    dub below, both anchored at the chunk's real start time. A target bar that
    sticks out past its source bar IS the drift — no legend needed to read it.
    Pause gaps are drawn hatched so the rhythm the dub has to preserve is
    visible rather than implied by empty space.

    Below the lanes, one editable row per chunk. Correcting a line re-measures
    it on the spot and moves its bar; Copy/Download hand back a complete plan
    file for the panel to reload.
    """
    total = float(total_dur_s or 0.0)
    if not total and plan:
        total = max(r["end_s"] + r.get("pause_after_s", 0.0) for r in plan)
    total = max(total, 1.0)

    counts = plan_counts(plan)
    rate = rate_override if rate_override else chars_per_sec(language)

    # ── Summary pills (JS repaints these; this is the no-script state) ────
    pills = []
    for key in _VERDICT_ORDER:
        n = counts.get(key, 0)
        if not n:
            continue
        label, colour, fg = _VERDICT_STYLE[key]
        pills.append(f'<span class="pill" style="background:{colour};'
                     f'color:{fg}">{n} {_esc(label)}</span>')

    # ── Ruler ────────────────────────────────────────────────────────────
    step = _ruler_step(total)
    ticks = []
    t = 0
    while t <= total:
        ticks.append(f'<div class="tick" style="left:calc({t} * var(--pxs) '
                     f'* 1px)">{_clock(t)}</div>')
        t += step

    # ── Bars ─────────────────────────────────────────────────────────────
    src_bars, tgt_bars, gaps = [], [], []
    for i, row in enumerate(plan):
        a, d = row["start_s"], max(row["dur_s"], 0.02)
        pause = row.get("pause_after_s", 0.0)
        est = max(row.get("est_s", 0.0), 0.0)
        label, colour, fg = _VERDICT_STYLE.get(row.get("verdict", "empty"),
                                               _VERDICT_STYLE["empty"])
        tip = (f'#{row["index"]}  {_clock(a)}  slot {d:.2f}s '
               f'+{pause:.2f}s pause  ·  est {est:.2f}s  ·  {label}')
        src_bars.append(
            f'<div class="bar src" id="sb{i}" style="left:calc({a:.3f} * '
            f'var(--pxs) * 1px);width:calc({d:.3f} * var(--pxs) * 1px)" '
            f'title="{_esc(tip)}">{row["index"]}. {_esc(row.get("en", ""))}'
            f'</div>')
        if pause > 0.01:
            gaps.append(
                f'<div class="pausegap" style="left:calc({row["end_s"]:.3f} '
                f'* var(--pxs) * 1px);width:calc({pause:.3f} * var(--pxs) '
                f'* 1px)" title="pause {pause:.2f}s"></div>')
        tgt_bars.append(
            f'<div class="bar indic" id="tb{i}" style="left:calc({a:.3f} * '
            f'var(--pxs) * 1px);width:calc({est:.3f} * var(--pxs) * 1px);'
            f'background:{colour};color:{fg}'
            f'{"" if est > 0 else ";display:none"}" title="{_esc(tip)}">'
            f'{_esc(row.get("tr", ""))}</div>')

    # ── Editable rows ────────────────────────────────────────────────────
    rows_html = []
    for i, row in enumerate(plan):
        verdict = row.get("verdict", "empty")
        label, colour, fg = _VERDICT_STYLE.get(verdict,
                                               _VERDICT_STYLE["empty"])
        rows_html.append(
            '<div class="row{hot}" id="row{i}">'
            '<div class="t"><b>#{idx}</b>{start}<br>slot {dur:.2f}s'
            '<br>+{pause:.2f}s pause</div>'
            '<div><div class="en">{en}</div>'
            '<div class="ed indic" id="ed{i}" contenteditable="true" '
            'spellcheck="false" role="textbox" aria-label="Target text for '
            'chunk {idx}">{tr}</div></div>'
            '<div class="side">'
            '<span class="v" id="v{i}" style="color:{colour}">{label}</span>'
            '<span id="n{i}"></span>'
            '<div class="meter"><span class="slot" id="ms{i}"></span>'
            '<span class="pausez" id="mp{i}"></span>'
            '<span class="est" id="me{i}"></span>'
            '<span class="edge" id="mg{i}"></span></div>'
            '<span id="a{i}"></span>'
            '</div></div>'.format(
                i=i, idx=row["index"], hot=" hot" if verdict == "over" else "",
                start=_clock(row["start_s"]), dur=row["dur_s"],
                pause=row.get("pause_after_s", 0.0),
                en=_esc(row.get("en", "")), tr=_esc(row.get("tr", "")),
                colour=colour, label=_esc(label)))

    # ── The payload the editor works from ────────────────────────────────
    header = PLAN_HEADER.format(
        ver=PLAN_FORMAT_VERSION, audio=os.path.basename(audio_path or ""),
        language=language or "?", n=len(plan), dur=total_dur_s,
        rate=rate, ceil=max_atempo)
    plan_name = os.path.basename(out_path).replace("_sync_plan.html",
                                                   "_sync_plan.txt")
    payload = {
        "rate": rate,
        "max_atempo": max_atempo,
        "short_ratio": SHORT_RATIO,
        "header": header,
        "plan_name": plan_name,
        "order": list(_VERDICT_ORDER),
        "style": {k: list(v) for k, v in _VERDICT_STYLE.items()},
        "rows": [{
            "index": r["index"],
            "start": round(float(r["start_s"]), 3),
            "end": round(float(r["end_s"]), 3),
            "dur": round(float(r["dur_s"]), 3),
            "pause": round(float(r.get("pause_after_s", 0.0)), 3),
            "en": " ".join((r.get("en", "") or "").split()),
            "tr": " ".join((r.get("tr", "") or "").split()),
        } for r in plan],
    }
    # ensure_ascii keeps the payload 7-bit, so no encoding surprise can
    # corrupt the target text on its way into the page; "</" is escaped
    # because a "</script>" inside a string would close the block early.
    data = json.dumps(payload, ensure_ascii=True).replace("</", "<\\/")

    over_n = counts.get("over", 0)
    if over_n:
        foot = (f"{over_n} chunk(s) overflow their slot. The paid run will "
                f"speed those up to at most {max_atempo:.2f}&times;; anything "
                "needing more than that is left long and flagged in the log "
                "rather than squashed. Shortening the line here is free and "
                "repeatable; only Approve in the panel spends credits.")
    else:
        foot = ("Every chunk fits. Approving will synthesize at these "
                "boundaries, with each chunk starting at its source "
                "timestamp.")

    doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Review &amp; sync — {_esc(os.path.basename(audio_path))}</title>
<style>{_CSS.replace("__PXS__", str(int(px_per_sec)))}</style>
</head><body>
<h1>Review &amp; sync — {_esc(os.path.basename(audio_path))}</h1>
<div class="sub">{_esc(language or "?")} &middot; {len(plan)} chunks from
detected pauses &middot; source {_clock(total)} &middot; estimated at
{rate:.1f} chars/sec &middot; <b>no audio generated, no credits spent</b></div>
<div class="counts" id="pills">{''.join(pills)}</div>

<div class="controls">
  <button id="badcount" type="button">Only problems</button>
  <label for="zoom">Zoom</label>
  <input id="zoom" type="range" min="10" max="240" value="{px_per_sec}"
         step="5" style="width:170px">
  <span id="zoomval">{px_per_sec} px/s</span>
  <span>&middot; grey = source speech, coloured = estimated dub, hatched =
  pause</span>
</div>

<div class="tlwrap">
  <div class="gutter">
    <div class="gspacer"></div>
    <div class="glabel">source</div>
    <div class="glabel">dub (est)</div>
  </div>
  <div class="scroller"><div class="track"
       style="width:calc({total:.3f} * var(--pxs) * 1px + 80px)">
    <div class="ruler">{''.join(ticks)}</div>
    <div class="lane">{''.join(src_bars)}{''.join(gaps)}</div>
    <div class="lane">{''.join(tgt_bars)}</div>
  </div></div>
</div>

<div id="rows">{''.join(rows_html)}</div>

<div class="savebar">
  <button class="pri" id="copy" type="button">Copy corrected plan</button>
  <button id="dl" type="button">Download plan file</button>
  <span id="dirty">no edits yet</span>
  <span id="flash"></span>
  <span style="flex:1 1 120px"></span>
  <span>Then in the panel: <b>Paste corrections</b> &rarr; the fit is
  re-measured against the audio.</span>
</div>

<p class="foot">{foot}</p>
<script>window.__PLAN__ = {data};</script>
<script>{_JS}</script>
</body></html>
"""
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(doc)
    return out_path
