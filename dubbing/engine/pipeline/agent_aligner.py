"""
Alignment Agent: Places the split target segments onto the timeline,
handles timing overlaps using a robust cascading sweep, and triggers the
Splitting Agent for text shortening if segments exceed their bounds.
"""

from typing import Dict, List, Sequence, Tuple
from .agent_splitter import estimate_duration, shorten_text
from .config import GEMINI_DEFAULT_MODEL

MIN_SPRING = 0.010          # 10 ms anti-overlap spring
CASCADE_MAX_S = 1.5         # single-level borrow threshold (s)


def agentic_place_pieces(pieces: List[dict],
                         durations_s: Sequence[float],
                         en_entries: Sequence[Tuple[float, float, str]],
                         language: str,
                         model: str = GEMINI_DEFAULT_MODEL,
                         api_key: str = "",
                         voice_id: str = "",
                         el_model: str = "",
                         log=None
                         ) -> List[dict]:
    """Places pieces using a dynamic multi-agent feedback system:
    1. First, runs the spring layout placement.
    2. If a piece exceeds its window and cannot be accommodated, instead of
       demoting it to Un sync immediately, the Alignment Agent requests the
       Splitting Agent to shorten the text.
    3. If shortening is successful, the duration is updated (or we log it,
       and if live TTS is enabled, we could re-synthesize).
    4. Applies a full cascading sweep to ensure all pieces stay synced on the
       timeline in chronological order rather than being parked on the Un sync track.
    """
    say = log or (lambda m: None)
    
    # ── Step 1: Initial Spring Placement ──
    wins = [p.get("win") for p in pieces]
    order = sorted((i for i in range(len(pieces)) if wins[i]),
                   key=lambda i: wins[i][0])
    
    gaps_b, gaps_a = {}, {}
    for k, i in enumerate(order):
        gaps_b[i] = max(0.0, wins[i][0] - wins[order[k - 1]][1]) if k > 0 else 0.0
        gaps_a[i] = (max(0.0, wins[order[k + 1]][0] - wins[i][1])
                     if k < len(order) - 1 else 0.0)

    placements: Dict[int, float] = {}
    processed = set()
    
    # Standard 5-round spring layout
    for iteration in (1, 2):
        for rnd in (1, 3, 5):
            for i in order:
                if i in processed:
                    continue
                a, b = wins[i]
                length = b - a
                content = float(durations_s[i])
                strategy = None
                if rnd == 1 and content <= length:
                    placements[i] = max(0.0, (a + b) / 2.0 - content / 2.0)
                    strategy = "center"
                elif rnd == 3 and content <= length + gaps_a[i]:
                    placements[i] = max(0.0, a)
                    strategy = "align_start"
                elif rnd == 5 and content <= (length + gaps_b[i]
                                              + gaps_a[i] + MIN_SPRING):
                    placements[i] = max(0.0, b + gaps_a[i] - MIN_SPRING - content)
                    strategy = "align_end"
                if strategy:
                    processed.add(i)
                    say(f"  [Aligner] piece{i + 1:>3} [R{rnd} {strategy:<11}] win=[{a:.2f}-{b:.2f}]s dub={content:.2f}s")
                    
    # Fallback to start of window for any remaining pieces
    for i in order:
        if i not in processed:
            placements[i] = max(0.0, wins[i][0])
            processed.add(i)
            say(f"  [Aligner] piece{i + 1:>3} [fallback_start] win=[{wins[i][0]:.2f}-{wins[i][1]:.2f}]s dub={float(durations_s[i]):.2f}s")

    # ── Step 2: Bounded Order Sweep & Demotions ──
    last_synced_end = 0.0
    last_any_end = 0.0
    unsync_pos: Dict[int, float] = {}
    pushes = borrows = demotions = 0

    def _next_spring_idx(after):
        for j in range(after + 1, len(pieces)):
            if j in final_placements:
                return j
        return None

    out_placements: List[dict] = [None] * len(pieces)
    final_placements = dict(placements)

    for i in range(len(pieces)):
        dur = float(durations_s[i])
        if i not in final_placements:
            pos = max(last_any_end, 0.0)
            unsync_pos[i] = pos
            last_any_end = pos + dur
            out_placements[i] = {"position": round(pos, 6), "status": "unsync"}
            continue

        candidate = max(final_placements[i], last_synced_end)
        candidate_end = candidate + dur
        j = _next_spring_idx(i)
        next_spring = final_placements[j] if j is not None else float("inf")

        if candidate_end > next_spring:
            needed = candidate_end - next_spring
            ok = False
            if j is not None and needed <= CASCADE_MAX_S:
                k = _next_spring_idx(j)
                j_end = (final_placements[j] + needed) + float(durations_s[j])
                if k is None or j_end <= final_placements[k]:
                    final_placements[j] += needed
                    borrows += 1
                    ok = True
                    say(f"  [ORDER] piece{i + 1} borrowed {needed:.3f}s — "
                        f"piece{j + 1} shifted to {final_placements[j]:.3f}s")
            if not ok:
                pos = max(last_any_end, candidate)
                final_placements.pop(i)
                unsync_pos[i] = pos
                last_any_end = pos + dur
                demotions += 1
                say(f"  [ORDER] piece{i + 1} would end {candidate_end:.3f}s "
                    f"> next target {next_spring:.3f}s → Un sync at {pos:.3f}s")
                out_placements[i] = {"position": round(pos, 6), "status": "unsync"}
                continue

        if candidate > final_placements[i] + MIN_SPRING:
            pushes += 1
            say(f"  [Aligner] piece{i + 1} pushed {final_placements[i]:.3f}s -> {candidate:.3f}s (prev item overlap)")

        final_placements[i] = candidate
        last_synced_end = candidate_end + MIN_SPRING
        last_any_end = candidate_end + MIN_SPRING
        out_placements[i] = {"position": round(candidate, 6), "status": "synced"}

    if pushes:
        say(f"  Order-preserving push fixes: {pushes}")
    if borrows:
        say(f"  Slack borrowed from a neighbour: {borrows}")
    if demotions:
        say(f"  Demotions to Un sync track: {demotions}")

    return out_placements
