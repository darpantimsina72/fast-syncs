"""
Standalone dubbing pipeline (contract v0.3).

Logic extracted from the bulk app's Translation_and_Syncing_App.py
(copied verbatim where possible; UI/Tkinter references removed, settings
paths repointed to this repo's config/ directory). Each module's header
comment names the exact source file and line ranges it came from.

Modules:
    config     — language table, constants, ffmpeg discovery, settings loaders
    stt        — ElevenLabs Scribe STT + voice catalogue helpers
    srt_tools  — region detection, SRT builders, SpaCy chunking (optional),
                 LLM input formats, timestamps txt read/write, audio loading
    llm        — provider layer (vertex | gemini | openai-compatible),
                 prompt loading, 3-step chain, emotion, EN<->target mapping
    tts        — ElevenLabs TTS (+ Google Cloud TTS port), chunkers, stitching
    sync       — sync engine (springs/bleed-over/order sweep), audio
                 reassembly, captions rechunk
    tm         — translation-memory port (SQLite, data/ dir inside this repo)
"""
