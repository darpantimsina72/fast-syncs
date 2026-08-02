#!/usr/bin/env python3
"""
Launcher for the Reaper dubbing engine (contract v0.3).

Adapted from the proven "fast syncs" run_sync.py launcher pattern. REAPER's
Lua panel starts this script in the background (macOS `... &`, Windows
`ExecProcess(cmd, -2)`), and this launcher does everything that cannot be
done portably from Lua:

  1. Clean and recreate the engine status directory.
  2. Spawn dub_engine.py with the SAME interpreter via subprocess.
  3. Tee the worker's combined stdout+stderr to status/engine_log.txt
     (utf-8, line-buffered) so the Lua poller can tail it live.
  4. Publish the CHILD pid to status/engine_pid.txt (for the Cancel button).
  5. On child exit, write the exit code to status/engine_done.txt LAST so
     the poller never sees a done marker before the log/manifest are final.

Do not remove this file or fold it into dub_engine.py: the panel launches
THIS script (RUN_DUB_PY in Dub_Pipeline_Panel.lua), never dub_engine.py,
which is only invoked directly for --selfcheck (setup_mac.command). Both
files are required.

Standard library only. No shell=True. Secrets never travel on the command
line — API keys are read from this repo's gitignored config/ directory by
the pipeline itself (config/llm_settings.json, config/tts_settings.json
and the key files they point at).

Every mode goes through this launcher, so the status-dir / log / pid /
done.txt behaviour is identical for full runs, staged runs, chunk
regeneration, LLM connection tests and voice-list fetches.

--app-dir is DEPRECATED as of v0.3 (the engine is standalone): it is still
accepted and forwarded for backward compatibility, and the engine logs a
warning and ignores it.

Usage:
    # one-shot (v0.1 behaviour)
    "<python>" run_dub.py --audio "<audio path>" --language <Language> \
        [--voice-id <ELid>] [--el-model <model>] [--steps full] [--no-emotion]

    # staged: stop after translation for script review
    "<python>" run_dub.py --audio "<audio path>" --language <Language> \
        --steps translate

    # staged: resume with the reviewed/edited translation text file
    "<python>" run_dub.py --audio "<audio path>" --language <Language> \
        --steps dub --script "<abs .txt>" [--no-emotion]

    # regenerate one chunk (text read from a file, never from argv)
    "<python>" run_dub.py --regen-chunk --language <Language> \
        --text-file "<abs .txt>" --out-wav "<abs .wav>"

    # test the configured LLM provider (one tiny call)
    "<python>" run_dub.py --test-llm

    # fetch the ElevenLabs voice catalogue for a language
    "<python>" run_dub.py --list-voices --language <Language>
"""

import argparse
import os
import shutil
import subprocess
import sys
import traceback

ENGINE_DIR = os.path.dirname(os.path.abspath(__file__))
STATUS_DIR = os.path.join(ENGINE_DIR, "status")

# The 11 target languages supported by the pipeline (display names).
LANGUAGES = ["Bengali", "Hindi", "Kannada", "Malayalam", "Tamil", "Telugu",
             "Gujarati", "Marathi", "Assamese", "Odia", "Nepali"]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Launch the headless dubbing engine (run_dub.py owns "
                    "log/pid/done markers; dub_engine.py does the work).")
    ap.add_argument("--app-dir", default=None,
                    help="DEPRECATED (v0.3): accepted for backward "
                         "compatibility and ignored by the standalone "
                         "engine (a warning is logged)")
    ap.add_argument("--audio", default=None,
                    help="Path to the English source audio file (required "
                         "unless --regen-chunk/--test-llm/--list-voices)")
    ap.add_argument("--language", default=None, choices=LANGUAGES,
                    help="Target language display name (required unless "
                         "--test-llm)")
    ap.add_argument("--voice-id", default=None,
                    help="Optional ElevenLabs voice_id (auto-resolved from "
                         "the account's voice catalogue when omitted)")
    ap.add_argument("--el-model", default="eleven_v3",
                    help="ElevenLabs TTS model id (default: eleven_v3)")
    ap.add_argument("--steps", default="full",
                    choices=["full", "translate", "dub"],
                    help="Pipeline scope: 'full' = one shot, 'translate' = "
                         "stop after the translation for script review, "
                         "'dub' = resume from a reviewed script "
                         "(requires --script)")
    ap.add_argument("--script", default=None,
                    help="Reviewed translation text file for --steps dub "
                         "(blank-line paragraph format)")
    ap.add_argument("--provided-script", dest="provided_script", default=None,
                    help="User-provided translation text file: skips the "
                         "LLM translation chain (S2a-S2c) in --steps "
                         "translate/full runs")
    ap.add_argument("--voice-change", dest="voice_change",
                    action="store_true",
                    help="Re-voice --in-wav with the ElevenLabs voice "
                         "changer (speech-to-speech) and write --out-wav")
    ap.add_argument("--in-wav", dest="in_wav", default=None,
                    help="Input audio file for --voice-change")
    ap.add_argument("--sts-model", dest="sts_model",
                    default="eleven_multilingual_sts_v2",
                    help="ElevenLabs speech-to-speech model for "
                         "--voice-change")
    ap.add_argument("--regen-chunk", dest="regen_chunk", action="store_true",
                    help="Regenerate ONE chunk: synthesize --text-file with "
                         "ElevenLabs and write --out-wav (no other stages)")
    ap.add_argument("--text-file", dest="text_file", default=None,
                    help="UTF-8 chunk text file for --regen-chunk (Indic "
                         "text never travels on argv)")
    ap.add_argument("--out-wav", dest="out_wav", default=None,
                    help="Output WAV path for --regen-chunk")
    ap.add_argument("--sync-mode", dest="sync_mode", default=None,
                    choices=["match", "legacy"],
                    help="v0.7 chunk-placement mode: 'match' (default) = "
                         "Gemini section matching + Auto-Sync-style "
                         "placement with Un sync statuses; 'legacy' = the "
                         "old whole-script TTS + re-transcription path")
    ap.add_argument("--emotion", dest="emotion", action="store_true",
                    default=None,
                    help="Force Step-4 emotion enrichment ON before TTS")
    ap.add_argument("--no-emotion", dest="emotion", action="store_false",
                    help="Skip Step-4 emotion enrichment before TTS")
    ap.add_argument("--test-llm", dest="test_llm", action="store_true",
                    help="Make one tiny LLM call on the configured provider "
                         "and write a {status, provider, model, reply} "
                         "manifest")
    ap.add_argument("--list-voices", dest="list_voices", action="store_true",
                    help="Fetch the ElevenLabs voice catalogue for "
                         "--language and write a {status, voices} manifest")
    ap.add_argument("--status-dir", dest="status_dir", default=None,
                    help="Per-run status directory (log/pid/done/manifest). "
                         "Must live inside engine/status/. The panel passes "
                         "one per REAPER project so concurrent runs from "
                         "two REAPER instances never clobber each other. "
                         "Default: engine/status itself.")
    args = ap.parse_args()

    # Mirror dub_engine.py's mode validation here so a bad launch dies with
    # a clear argparse message instead of deep inside the detached child.
    if args.test_llm:
        if args.regen_chunk or args.list_voices or args.voice_change:
            ap.error("--test-llm cannot be combined with other modes")
    elif args.list_voices:
        if args.regen_chunk or args.voice_change:
            ap.error("--list-voices cannot be combined with other modes")
        if not args.language:
            ap.error("--list-voices requires --language")
    elif args.voice_change:
        if args.regen_chunk:
            ap.error("--voice-change cannot be combined with --regen-chunk")
        if not args.language:
            ap.error("--voice-change requires --language")
        if not args.in_wav:
            ap.error("--voice-change requires --in-wav <input audio path>")
        if not args.out_wav:
            ap.error("--voice-change requires --out-wav <output wav path>")
        if args.script or args.provided_script or args.text_file:
            ap.error("--script/--provided-script/--text-file are not valid "
                     "with --voice-change")
    elif args.regen_chunk:
        if not args.language:
            ap.error("--regen-chunk requires --language")
        if not args.text_file:
            ap.error("--regen-chunk requires --text-file <utf-8 chunk text>")
        if not args.out_wav:
            ap.error("--regen-chunk requires --out-wav <output wav path>")
        if args.script or args.provided_script:
            ap.error("--script/--provided-script are not valid with "
                     "--regen-chunk")
    else:
        if not args.audio:
            ap.error("--audio is required unless "
                     "--regen-chunk/--test-llm/--list-voices/--voice-change")
        if not args.language:
            ap.error("--language is required unless --test-llm")
        if args.steps == "dub" and not args.script:
            ap.error("--steps dub requires --script <translation text "
                     "file> — run '--steps translate' first, review/edit "
                     "its translation_text file, then pass that file here")
        if args.script and args.steps != "dub":
            ap.error("--script is only valid with --steps dub")
        if args.provided_script and args.steps == "dub":
            ap.error("--provided-script is only valid with --steps "
                     "translate/full")
        if args.text_file or args.out_wav or args.in_wav:
            ap.error("--text-file/--out-wav/--in-wav are only valid with "
                     "--regen-chunk / --voice-change")

    # Resolve the status directory. A per-run override must stay inside
    # engine/status/ — this launcher rmtree's the target, so an arbitrary
    # path would be a foot-gun.
    status_dir = STATUS_DIR
    if args.status_dir:
        cand = os.path.abspath(args.status_dir)
        root = os.path.abspath(STATUS_DIR)
        if cand != root and not cand.startswith(root + os.sep):
            ap.error(f"--status-dir must be {root} or a subdirectory of it "
                     f"(got: {cand})")
        status_dir = cand

    # Clean the status directory so the Lua poller only ever sees files from
    # THIS run (a stale engine_done.txt would end the poll early). A
    # per-project subdir is cleaned wholesale; the shared root is cleaned
    # file-by-file so a legacy (no --status-dir) launch can never wipe a
    # sibling project's live run underneath it.
    if status_dir != os.path.abspath(STATUS_DIR):
        shutil.rmtree(status_dir, ignore_errors=True)
    else:
        for name in ("engine_log.txt", "engine_pid.txt",
                     "engine_done.txt", "engine_done.json"):
            try:
                os.remove(os.path.join(status_dir, name))
            except OSError:
                pass
    os.makedirs(status_dir, exist_ok=True)

    log_path = os.path.join(status_dir, "engine_log.txt")
    pid_path = os.path.join(status_dir, "engine_pid.txt")
    done_path = os.path.join(status_dir, "engine_done.txt")

    # Force UTF-8 in the worker: the pipeline prints Indic text and unicode
    # symbols, and on Windows a redirected stdout defaults to the legacy ANSI
    # code page, which would raise UnicodeEncodeError and kill the run.
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    # Tell dub_engine.py where to write its engine_done.json manifest — it
    # must land in the same per-run dir as this launcher's log/pid/done.
    env["DUB_STATUS_DIR"] = status_dir

    log_file = open(log_path, "w", encoding="utf-8", errors="replace")
    exit_code = 1
    proc = None
    try:
        engine_script = os.path.join(ENGINE_DIR, "dub_engine.py")
        if not os.path.exists(engine_script):
            log_file.write(f"[run_dub] ERROR: dub_engine.py not found at "
                           f"{engine_script}\n")
            log_file.flush()
            return 1

        cmd = [sys.executable, "-u", engine_script,
               "--el-model", args.el_model]
        if args.language:
            cmd += ["--language", args.language]
        if args.app_dir:
            # Deprecated: forwarded so the engine logs its own warning and
            # legacy panel launch commands keep working unchanged.
            log_file.write("[run_dub] note: --app-dir is deprecated (v0.3) "
                           "and ignored by the standalone engine.\n")
            cmd += ["--app-dir", args.app_dir]
        if args.test_llm:
            cmd.append("--test-llm")
        elif args.list_voices:
            cmd.append("--list-voices")
        elif args.voice_change:
            cmd += ["--voice-change",
                    "--in-wav", args.in_wav,
                    "--out-wav", args.out_wav,
                    "--sts-model", args.sts_model]
        elif args.regen_chunk:
            cmd += ["--regen-chunk",
                    "--text-file", args.text_file,
                    "--out-wav", args.out_wav]
        else:
            cmd += ["--audio", args.audio, "--steps", args.steps]
            if args.steps == "dub":
                cmd += ["--script", args.script]
            if args.provided_script:
                cmd += ["--provided-script", args.provided_script]
            if args.sync_mode:
                cmd += ["--sync-mode", args.sync_mode]
        if args.voice_id and args.voice_id.strip():
            cmd += ["--voice-id", args.voice_id.strip()]
        # Tri-state emotion pass-through: only forward an explicit choice so
        # the engine's own default resolution (settings file, then ON) holds.
        if args.emotion is True:
            cmd.append("--emotion")
        elif args.emotion is False:
            cmd.append("--no-emotion")

        log_file.write("[run_dub] launching: "
                       + " ".join(f'"{c}"' if " " in c else c for c in cmd)
                       + "\n")
        log_file.flush()

        popen_kwargs = {}
        if os.name == "nt":
            # No visible console window when launched detached from REAPER.
            popen_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        else:
            # New session so Cancel can signal the whole worker tree.
            popen_kwargs["start_new_session"] = True

        proc = subprocess.Popen(
            cmd,
            cwd=ENGINE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,                      # line-buffered text pipe
            **popen_kwargs,
        )

        # Publish the CHILD pid immediately (the launcher's own pid is
        # useless for Cancel — killing it would orphan the worker).
        try:
            with open(pid_path, "w", encoding="utf-8") as pf:
                pf.write(str(proc.pid))
        except Exception:
            pass

        # Tee: every worker line goes to the log file (flushed per line so
        # the Lua poller sees it live) and, best-effort, to our own stdout.
        # stdout may be an invalid handle when REAPER starts us detached, so
        # the echo must never be allowed to crash the tee loop.
        for line in proc.stdout:
            log_file.write(line)
            log_file.flush()
            try:
                sys.stdout.write(line)
                sys.stdout.flush()
            except Exception:
                pass

        proc.wait()
        exit_code = proc.returncode
    except Exception:
        try:
            log_file.write("\n[run_dub] launcher crashed:\n")
            log_file.write(traceback.format_exc())
            log_file.flush()
        except Exception:
            pass
        exit_code = 1
    finally:
        try:
            log_file.close()
        except Exception:
            pass
        # Worker is gone — drop the stale pid file so a later Cancel cannot
        # signal an unrelated, recycled PID.
        try:
            os.remove(pid_path)
        except OSError:
            pass
        # The done marker is written LAST — it is the poller's only signal
        # that log + manifest are complete.
        try:
            with open(done_path, "w", encoding="utf-8") as df:
                df.write(str(exit_code))
        except Exception:
            pass

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
