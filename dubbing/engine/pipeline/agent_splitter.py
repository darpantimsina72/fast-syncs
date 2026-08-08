"""
Splitting Agent: Dynamically divides and rephrases script translations based on
timing windows and estimated speech durations.
"""

import re
from typing import Dict, List, Tuple, Sequence
from .llm import _llm_generate
from .config import GEMINI_DEFAULT_MODEL

# Estimated speaking rate: characters per second depending on language
LANG_CHARS_PER_SEC = {
    "Hindi": 9.2,      # Hindi is spoken slower on ElevenLabs
    "Marathi": 12.0,
    "Bengali": 12.0,
    "Gujarati": 11.0,
    "Tamil": 12.0,
    "Telugu": 11.5,
    "Kannada": 11.5,
    "Malayalam": 12.0,
    "Sanskrit": 10.0,
    "English": 14.0,
}
DEFAULT_CHARS_PER_SEC = 11.0


def estimate_duration(text: str, language: str = "") -> float:
    """Estimate spoken duration of text in seconds based on character count and language."""
    clean_text = re.sub(r"\[.*?\]", "", text).strip()  # remove tags
    rate = LANG_CHARS_PER_SEC.get(language, DEFAULT_CHARS_PER_SEC) if language else DEFAULT_CHARS_PER_SEC
    return len(clean_text) / rate


def shorten_text(tr_text: str, en_text: str, target_dur: float, language: str,
                 model: str = GEMINI_DEFAULT_MODEL, status_cb=None,
                 prev_ctx: str = "", next_ctx: str = "") -> str:
    """Use Gemini to shorten a translation text to fit a target duration, with dialogue context."""
    if status_cb:
        status_cb(f"    [Splitter] Shortening text: '{tr_text}' to fit {target_dur:.1f}s...")

    prompt = (
        f"You are an expert audio dubbing editor. Shorten the following translated text ({language}) "
        f"so that it can be naturally spoken in under {target_dur:.1f} seconds.\n"
        f"Maintain the core semantic meaning and style of the original English phrase as closely as possible. "
        f"Use the surrounding dialogue context to ensure correct vocabulary and word meanings (for example, "
        f"translating 'nailed' correctly in context as 'crucified/सूली पर चढ़ाया' rather than slang/literal translations).\n\n"
        f"Context of surrounding dialogue:\n"
        f"Previous lines: \"{prev_ctx}\"\n"
        f"Next lines: \"{next_ctx}\"\n\n"
        f"Original English: \"{en_text}\"\n"
        f"Current translation to shorten: \"{tr_text}\"\n\n"
        f"Do NOT add any commentary or explanation — output ONLY the shortened translation.\n"
        f"Shortened translation:"
    )

    result = _llm_generate(prompt, model, role="match").strip()
    # Strip quotes if the LLM wrapped it
    result = re.sub(r'^["\'“‘](.*?)["\'”’]$', r'\1', result).strip()

    if status_cb:
        status_cb(f"    [Splitter] Shortened: '{tr_text}' -> '{result}' "
                  f"(estimated: {estimate_duration(result, language):.1f}s)")
    return result


def agentic_split_match(en_entries: Sequence[Tuple[float, float, str]],
                        tr_sentences: Sequence[str],
                        language: str,
                        model: str = GEMINI_DEFAULT_MODEL,
                        status_cb=None
                        ) -> Tuple[List[Dict[str, List[int]]], List[int], List[int], List[str]]:
    """Splitting Agent orchestrates the match process:
    1. Runs the initial semantic matching to group TR sentences with EN cues.
    2. Checks each matched group's duration. If a translation is too long for its window,
       rephrases it to fit.
    """
    from .match import call_match_sections
    
    sections, unmatched_tr, unmatched_en = call_match_sections(
        en_entries, tr_sentences, language, model, status_cb
    )

    # Make a copy of tr_sentences so we can modify translations in-place
    modified_sentences = list(tr_sentences)

    for s in sections:
        if not s["en"] or not s["tr"]:
            continue
        
        # Calculate target window duration
        win_a = min(en_entries[i - 1][0] for i in s["en"])
        win_b = max(en_entries[i - 1][1] for i in s["en"])
        window_dur = win_b - win_a

        # Gather current translation text and English text
        tr_ids = sorted(s["tr"])
        en_ids = sorted(s["en"])
        
        tr_text = " ".join(modified_sentences[j - 1].strip() for j in tr_ids)
        en_text = " ".join(en_entries[i - 1][2].strip() for i in en_ids)

        est_dur = estimate_duration(tr_text, language)

        # If estimated duration overruns target window by more than 15% (or 0.5s)
        if est_dur > max(window_dur * 1.15, window_dur + 0.5):
            # Extract previous and next lines for semantic context
            prev_context = []
            for p_id in range(max(1, tr_ids[0] - 2), tr_ids[0]):
                prev_context.append(modified_sentences[p_id - 1])
            prev_ctx_str = " | ".join(prev_context)

            next_context = []
            for n_id in range(tr_ids[-1] + 1, min(len(modified_sentences) + 1, tr_ids[-1] + 3)):
                next_context.append(modified_sentences[n_id - 1])
            next_ctx_str = " | ".join(next_context)

            # We need to shorten!
            shortened = shorten_text(
                tr_text, en_text, window_dur, language, model, status_cb,
                prev_ctx=prev_ctx_str, next_ctx=next_ctx_str
            )
            
            # Distribute the shortened text back to the first sentence in the group,
            # and empty the others.
            if tr_ids:
                modified_sentences[tr_ids[0] - 1] = shortened
                for extra_id in tr_ids[1:]:
                    modified_sentences[extra_id - 1] = ""

    return sections, unmatched_tr, unmatched_en, modified_sentences
