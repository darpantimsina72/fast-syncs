"""
Translation Memory — proofed-translation feedback loop
=======================================================
Stores human-proofed translations (captured when a reviewed script is
confirmed for dubbing) and serves them back at translation time so
identical content never hits the LLM twice.

Ported verbatim from the bulk app's translation_memory.py (226 lines);
the only adaptation is the default DB path, which now resolves to THIS
repo's data/ directory (data/translation_memory.db) instead of the app
install's data/ folder.

Two granularities:
  • full_docs — the entire proofed translation keyed by a hash of the
    normalized English transcript. Re-running the same audio (regen,
    duplicate batch entry, re-processing) reuses the whole proofed script
    for zero tokens.
  • pairs — English-segment → translation-paragraph pairs (as shown in the
    review flow), injected into the translation prompt as approved
    reference translations when the same English appears in new content.

Storage: SQLite at <repo>/data/translation_memory.db
(env TRANSLATION_MEMORY_DB overrides). Conventions carried over from the
source repo: per-thread connections (threading.local), journal_mode=DELETE,
busy_timeout, and fail-open writes — a storage error must never break the
pipeline. Lookups fail-closed to "no match" (pipeline just translates
normally).

TM_REUSE_DISABLE=1 turns OFF all memory reuse (lookups return nothing)
while capture keeps running — the emergency lever if a bad proofed script
ever needs to be bypassed until it is re-proofed.
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
import threading
import time
from pathlib import Path

log = logging.getLogger("translation_memory")

# This file lives at <repo>/engine/pipeline/tm.py — parents[2] is the repo
# root, so the default DB path is <repo>/data/translation_memory.db.
DB_PATH = os.getenv(
    "TRANSLATION_MEMORY_DB",
    str(Path(__file__).resolve().parents[2] / "data" / "translation_memory.db"),
)

_local = threading.local()

_SCHEMA = """
CREATE TABLE IF NOT EXISTS full_docs (
    language   TEXT NOT NULL,
    en_hash    TEXT NOT NULL,
    en_text    TEXT NOT NULL,
    doc_text   TEXT NOT NULL,
    source     TEXT,
    proofed_at REAL,
    PRIMARY KEY (language, en_hash)
);
CREATE TABLE IF NOT EXISTS pairs (
    language    TEXT NOT NULL,
    en_norm     TEXT NOT NULL,
    en_text     TEXT NOT NULL,
    translation TEXT NOT NULL,
    source      TEXT,
    proofed_at  REAL,
    PRIMARY KEY (language, en_norm)
);
"""


def _get_conn():
    conn = getattr(_local, "conn", None)
    if conn is not None:
        return conn
    import sqlite3
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.execute("PRAGMA busy_timeout=10000")
    conn.executescript(_SCHEMA)
    conn.commit()
    _local.conn = conn
    return conn


# ── Text normalization ───────────────────────────────────────────────────────

def normalize(text: str) -> str:
    """Whitespace-collapsed, case-folded form used as the match key."""
    return " ".join((text or "").split()).casefold()


def source_hash(text: str) -> str:
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


# Segments with no word character (pause fences like "...", stray dashes)
# are universal filler, not translatable text: never stored as pairs.
_WORD_RE = re.compile(r"\w", re.UNICODE)


def is_trivial(segment: str) -> bool:
    return not _WORD_RE.search(segment or "")


# ── Writes (fail-open: never raise into the pipeline) ────────────────────────

def _safe(fn):
    def wrapper(*a, **kw):
        try:
            return fn(*a, **kw)
        except Exception as e:
            log.error(f"translation_memory.{fn.__name__} failed (ignored): {e}")
            # Roll back any open transaction so this thread's cached
            # connection isn't left holding locks.
            try:
                _get_conn().rollback()
            except Exception:
                pass
            return None
    return wrapper


@_safe
def store_full(language: str, en_text: str, doc_text: str, source: str = "") -> None:
    """Store the whole proofed translation keyed by the English source hash."""
    if not (language and en_text and doc_text):
        return
    conn = _get_conn()
    conn.execute(
        "INSERT OR REPLACE INTO full_docs (language, en_hash, en_text, doc_text, source, proofed_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (language, source_hash(en_text), en_text, doc_text, source, time.time()),
    )
    conn.commit()


@_safe
def store_pairs(language: str, pair_list: list, source: str = "") -> int:
    """pair_list: [(english_text, translated_text), ...]. Returns rows stored."""
    if not (language and pair_list):
        return 0
    conn = _get_conn()
    now = time.time()
    stored = 0
    for en, tr in pair_list:
        en, tr = (en or "").strip(), (tr or "").strip()
        if not en or not tr or is_trivial(en) or is_trivial(tr):
            continue
        conn.execute(
            "INSERT OR REPLACE INTO pairs (language, en_norm, en_text, translation, source, proofed_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (language, normalize(en), en, tr, source, now),
        )
        stored += 1
    conn.commit()
    return stored


# ── Reads (fail-closed to "no match") ────────────────────────────────────────

def _reuse_disabled() -> bool:
    return os.getenv("TM_REUSE_DISABLE", "").strip().lower() in {"1", "true", "yes"}


def lookup_full(language: str, en_text: str):
    """Proofed full translation for this exact (normalized) English source, or None."""
    if _reuse_disabled():
        return None
    try:
        row = _get_conn().execute(
            "SELECT doc_text FROM full_docs WHERE language = ? AND en_hash = ?",
            (language, source_hash(en_text)),
        ).fetchone()
        return row[0] if row else None
    except Exception as e:
        log.error(f"translation_memory.lookup_full failed (ignored): {e}")
        return None


def lookup_pairs_in_source(language: str, source_text: str, cap: int = 40) -> list:
    """Proofed (english, translation) pairs whose English appears verbatim
    (after normalization) inside *source_text*. Newest first, capped.

    Pairs are stored at review-row granularity (grouped English segments →
    one translation paragraph), so substring containment — not per-sentence
    hashing — is the right match. The table is small (one row per reviewed
    paragraph), so scanning the language's rows in Python is fine for a
    desktop app.
    """
    if _reuse_disabled():
        return []
    try:
        src_norm = normalize(source_text)
        if not src_norm:
            return []
        out = []
        for en_text, tr in _get_conn().execute(
            "SELECT en_text, translation FROM pairs WHERE language = ? "
            "ORDER BY proofed_at DESC",
            (language,),
        ):
            if normalize(en_text) in src_norm:
                out.append((en_text, tr))
                if len(out) >= cap:
                    break
        return out
    except Exception as e:
        log.error(f"translation_memory.lookup_pairs_in_source failed (ignored): {e}")
        return []


def stats() -> dict:
    """{'full_docs': n, 'pairs': n} — for status displays. Fail-closed to zeros."""
    try:
        conn = _get_conn()
        docs = conn.execute("SELECT COUNT(*) FROM full_docs").fetchone()[0]
        pairs = conn.execute("SELECT COUNT(*) FROM pairs").fetchone()[0]
        return {"full_docs": docs, "pairs": pairs}
    except Exception:
        return {"full_docs": 0, "pairs": 0}
