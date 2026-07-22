"""
One-shot helper: generates first-draft per-language prompt files for the 10
new languages by adapting the Bengali source prompts. Substitutes language
names and prepends a "use native script" header. Run once after authoring
the Bengali source; review the output and refine per-language as needed.

Usage: python prompts/_generate_drafts.py
"""
import os
import re

LANGUAGES = {
    # name        autonym        native-name in source-language register notes
    "Hindi":     ("हिन्दी",      "Khari Boli / standard conversational Hindi"),
    "Kannada":   ("ಕನ್ನಡ",       "modern spoken Kannada, not literary"),
    "Malayalam": ("മലയാളം",      "modern spoken Malayalam, not literary"),
    "Assamese":  ("অসমীয়া",     "modern spoken Assamese"),
    "Odia":      ("ଓଡ଼ିଆ",       "modern spoken Odia"),
    "Nepali":    ("नेपाली",      "standard conversational Nepali"),
    "Tamil":     ("தமிழ்",       "modern spoken Tamil (centhamizh-free), not Senthamizh"),
    "Telugu":    ("తెలుగు",       "modern spoken Telugu"),
    "Gujarati":  ("ગુજરાતી",      "modern spoken Gujarati"),
    "Marathi":   ("मराठी",        "standard conversational Marathi"),
}

# Devanagari-script languages use the daṛi-equivalent `।`. Other scripts use
# Western full-stop. Tamil/Telugu/Kannada/Malayalam/Gujarati/Odia use `.`.
DEVANAGARI = {"Hindi", "Marathi", "Nepali"}

STAGES = (
    "Step1_Translation_Prompt",
    "Step2_Review_Prompt",
    "Step3_Punctuation_Prompt",
    "SyncingPrompt",
)

HERE = os.path.dirname(os.path.abspath(__file__))


def adapt(source: str, language: str, autonym: str, register_note: str) -> str:
    """Adapt a Bengali prompt body for *language*."""
    out = source

    # Whole-word substitutions. Order matters: do compound forms first.
    pairs = [
        ("Bengali (Bangla)",  f"{language} ({autonym})"),
        ("Bengali / Bangla",  f"{language} / {autonym}"),
        ("Bengali/Bangla",    f"{language} / {autonym}"),
        ("Bengali",           language),
        ("Bangla",            language),
        ("বাংলা",              autonym),
    ]
    for src, dst in pairs:
        out = out.replace(src, dst)

    # daṛi handling: only Devanagari-script languages use `।`. For others,
    # replace stray `।` references in commentary with `.`. But the Bengali
    # examples in the file are themselves in Bangla script — we can't
    # mechanically transliterate them. Add a header making this explicit.
    if language not in DEVANAGARI:
        # The dari character `।` is not native; mention it
        pass

    header = (
        f"### Target language: {language} ({autonym})\n"
        f"### Register: {register_note}\n"
        f"### NOTE FROM PIPELINE: This prompt is adapted from the original\n"
        f"### Bengali prompt. Structural rules (pause handling with `...`,\n"
        f"### hyphen `-` usage, paragraph breaks, thought-unit mapping)\n"
        f"### apply UNCHANGED to {language}. The example Bengali sentences\n"
        f"### below are STRUCTURAL templates — produce equivalent output in\n"
        f"### {language}'s native script ({autonym}). Translate, do not\n"
        f"### transliterate. Where the original mentions Bengali-specific\n"
        f"### punctuation (e.g. the daṛi `।`), apply the equivalent rule for\n"
        f"### {language}: "
        + ("use the daṛi `।` for sentence boundaries (Devanagari script)."
           if language in DEVANAGARI
           else "use the Western full-stop `.` for sentence boundaries.")
        + "\n\n"
    )

    return header + out


def main() -> None:
    for stage in STAGES:
        src_path = os.path.join(HERE, f"{stage}_Bengali.txt")
        if not os.path.exists(src_path):
            print(f"!! missing source: {src_path}")
            continue
        with open(src_path, "r", encoding="utf-8") as f:
            src = f.read()
        for lang, (autonym, register) in LANGUAGES.items():
            dst_path = os.path.join(HERE, f"{stage}_{lang}.txt")
            if os.path.exists(dst_path):
                print(f"-- skip (exists): {dst_path}")
                continue
            body = adapt(src, lang, autonym, register)
            with open(dst_path, "w", encoding="utf-8") as f:
                f.write(body)
            print(f"++ wrote: {os.path.basename(dst_path)}")


if __name__ == "__main__":
    main()
