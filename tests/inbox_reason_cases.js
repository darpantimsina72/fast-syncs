/*
 * Log excerpts for tests/test_inbox_reason.js.
 *
 * The error lines are copied from real report logs (Sept–Oct 2026) and from
 * the messages the Python code prints. Names, transcripts, project paths and
 * hostnames are left out: this repo is public.
 *
 * expect: the rule id that must win, or null for "no error rule may fire".
 */
'use strict';

const HEADER = [
  '==== Fast Syncs run log ====',
  'App version: 0.15.8',
  'Pipeline:    DubFull-translate',
  'Result:      failed',
  '============================'
].join('\n');

module.exports = [
  {
    name: 'dub: ElevenLabs key missing (Windows, CRLF)',
    log: [HEADER, '[engine] Importing pipeline modules…',
      'Traceback (most recent call last):',
      'ValueError: No ElevenLabs API key configured.',
      'RuntimeError: ElevenLabs API key unavailable: No ElevenLabs API key configured.',
      '[engine] Run FAILED — error manifest written.'].join('\r\n'),
    expect: 'elevenlabs_key_missing'
  },
  {
    name: 'dub: gateway 524 on a long translation',
    log: [HEADER, '[S1b] 607 regions', '[S2a] Translation chain running on gemini-2.5-pro…',
      'urllib.error.HTTPError: HTTP Error 524: <none>',
      'The above exception was the direct cause of the following exception:',
      'RuntimeError: LLM endpoint https://gateway.example/v1/chat/completions returned HTTP 524: error code: 524',
      '[engine] Run FAILED — error manifest written.'].join('\n'),
    expect: 'llm_timeout_524'
  },
  {
    name: 'dub: gateway 502 at the reachability check',
    log: [HEADER, '[engine] Checking the LLM is reachable (openai, gemini-3-flash-preview)…',
      'urllib.error.HTTPError: HTTP Error 502: Bad Gateway',
      'RuntimeError: LLM endpoint https://gateway.example/v1/chat/completions returned HTTP 502: error code: 502'].join('\n'),
    expect: 'llm_down_502'
  },
  {
    name: 'sync: office gateway unreachable → names the cause, not the umbrella',
    log: ['  EN: 56 items | DUB: 1 items',
      '    [GATEWAY] Error: <urlopen error [Errno 60] Operation timed out>',
      '    [GATEWAY] No response from gateway — aborting (backend=gateway)',
      '  [ERROR] Batch 1/3 failed — aborting',
      '  [ERROR] Gemini matching failed — sectioned AND batched attempts both returned nothing.'].join('\n'),
    expect: 'gateway_unreachable'
  },
  {
    name: 'sync: matching failed with no deeper cause',
    log: ['  EN: 20 items | DUB: 20 items',
      '  [ERROR] Gemini matching failed — sectioned AND batched attempts both returned nothing.'].join('\n'),
    expect: 'matching_failed'
  },
  {
    name: 'sync: English one clip, "36/36 matched" (ok run, 1 star)',
    status: 'ok',
    log: ['  EN: 1 items | DUB: 36 items',
      '  [ERROR] Sectioned response contained no usable sections — treating as a failed call',
      '  [WARN] Sectioned call failed — falling back to batched pairs',
      '  Sec   1 [iter1 R1 center     ] slot=[0.00-110.50]s gap_b=0.00s gap_a=0.00s dub=68.51s (36 clips)',
      '  RESULT: 36/36 matched, 0 unmatched'].join('\n'),
    expect: 'english_not_split'
  },
  {
    name: 'sync: English one clip + some unmatched → not-split wins',
    status: 'ok',
    log: ['  EN: 1 items | DUB: 100 items', '    [11LABS] ""',
      '  RESULT: 86/100 matched, 14 unmatched'].join('\n'),
    expect: 'english_not_split'
  },
  {
    name: 'sync: English one clip that the new auto-split DID cut → no not-split reason',
    status: 'ok',
    log: ['  EN: 1 items | DUB: 36 items',
      '  [SPLIT] EN clips for matching: 1 → 14',
      '  RESULT: 36/36 matched, 0 unmatched'].join('\n'),
    expect: null
  },
  {
    name: 'sync: auto-split could not cut',
    status: 'ok',
    log: ['  EN: 1 items | DUB: 36 items',
      '  [SPLIT] EN clips for matching: 1 → 1',
      '  [WARN] LONG_EN_NOT_SPLIT: English clip at 0.0s is 110s long and could not be cut into sentences.'].join('\n'),
    expect: 'english_split_failed'
  },
  {
    name: 'dub: section-size pieces (ok run, 1 star)',
    status: 'ok',
    log: [HEADER, '[S2d] Piece size: section.', '[S2d]     [Splitter] Shortening 4 section(s)',
      '[S3d]   17 synced / 0 unsync', '[engine] Run complete — manifest written.'].join('\n'),
    expect: 'section_pieces'
  },
  {
    name: 'dub: speech reused (ok run, 1 star)',
    status: 'ok',
    log: [HEADER, '[S2d] Reusing the speech from the previous run — same script, same voice, same model: x_tts.wav',
      '[S3d] 72 subtitles synced.', '[engine] Run complete — manifest written.'].join('\n'),
    expect: 'speech_reused'
  },
  {
    name: 'ElevenLabs 401 with quota_exceeded → credits, not key',
    log: ['    [11LABS] HTTP 401: {"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}',
      '  [ERROR] Transcription produced NO text (EN empty: 12/12)'].join('\n'),
    expect: 'elevenlabs_credits'
  },
  {
    name: 'Cloudflare 1010 is not reported as a bad key',
    log: ['RuntimeError: LLM endpoint https://gateway.example/v1/chat/completions returned HTTP 403 with Cloudflare "error code: 1010"'].join('\n'),
    expect: 'cloudflare_1010'
  },
  {
    name: 'broken venv',
    log: ['Traceback (most recent call last):', "ModuleNotFoundError: No module named 'pydub'"].join('\n'),
    expect: 'install_broken'
  },
  {
    name: 'ffmpeg missing',
    log: ['RuntimeError: ffmpeg not found — the engine needs it to decode TTS audio'].join('\n'),
    expect: 'ffmpeg_missing'
  },
  {
    name: 'warning only, but the run FAILED → not passed off as the cause',
    log: [HEADER, '[S2d] Piece size: section.',
      'Traceback (most recent call last):', 'KeyError: \'start\'',
      '[engine] Run FAILED — error manifest written.'].join('\n'),
    expect: null
  },
  {
    name: 'healthy Auto Sync run',
    status: 'ok',
    log: ['[run_sync] launching:', '  EN: 42 items | DUB: 40 items',
      '============================================================', '  STEP 1', '    [11LABS] "hello"',
      '  ✓ Sections: 6 | unmatched_dub: 0 | unmatched_en: 2', '[CACHE] Saved 82 entries',
      '  RESULT: 40/40 matched, 0 unmatched', 'Total time: 61s'].join('\n'),
    expect: null
  },
  {
    name: 'healthy dub run (clause pieces, match mode)',
    status: 'ok',
    log: [HEADER, '[engine] Sync mode: match', '[S1a] Transcribing English…', '[S2d] Piece size: clause.',
      '[S3d]   40 synced / 0 unsync', '[engine] Run complete — manifest written.'].join('\n'),
    expect: null
  }
];
