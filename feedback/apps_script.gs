/**
 * Fast Syncs team inbox — Google Apps Script web app.
 *
 * Receives the in-app "Send report" / "Send Feedback" posts and:
 *   1. saves the run log (and any screenshots) as files in one private
 *      Google Drive folder, one sub-folder per report,
 *   2. adds a row to a Google Sheet (date, stars, pipeline, message, link,
 *      reason),
 *   3. emails the owner for every report (bad ones marked ⚠ in the subject).
 *
 * The email is complete on its own, so it can be forwarded to whoever sent
 * the report: their details and message, then the REASON the run went wrong
 * (read from the log) and what to do about it, the log lines that show it,
 * the end of the log, and the full log as an attachment.
 *
 * How the reason is found — two layers:
 *   - RULES below: known errors, recognised by exact text in the log. Free,
 *     instant, always on. When a new kind of error turns up, add a rule.
 *   - An optional AI read of the log, used only when no rule matches. Off
 *     until a Gemini key is saved as the script property GEMINI_API_KEY
 *     (Project Settings → Script properties). The key never goes in this file:
 *     the repo is public.
 *
 * The web app can only ADD reports. Nothing it returns reveals other reports,
 * so its URL is safe to ship inside the app. It rejects posts without the
 * team code, oversized posts, and floods (per-hour cap).
 *
 * Setup: see feedback/SETUP.md. Fill the CONFIG values below.
 */

var CONFIG = {
  TEAM_CODE: 'CHANGE-ME',          // same value as "team_code" in feedback_config.json
  NOTIFY_EMAIL: '',                // who gets the emails ('' = the script's owner)
  FOLDER_NAME: 'Fast Syncs Reports',
  MAX_BODY_BYTES: 12 * 1024 * 1024, // reject anything bigger (log tail is ~1.5 MB)
  MAX_PER_HOUR: 60,                 // flood guard across all senders
  EMAIL_TAIL_LINES: 40,             // how much of the end of the log is printed in the email
  AI_MODELS: ['gemini-2.5-flash', 'gemini-flash-latest'], // tried in order; script property AI_MODEL overrides
  AI_LOG_LINES: 400                 // how much of the end of the log the AI reads
};

// ─────────────────────────────────────────────────────────────────────────────
// Known errors. Each rule: a pattern that finds it in ONE log line, and three
// plain-language sentences written for the person who sent the report —
// what went wrong, why, and what to do. `level` is 'error' (the run broke) or
// 'warn' (the run finished but this explains a bad result). Optional
// `unless`: the rule is skipped when any line of the log matches it.
// When several rules match, errors win over warnings, then the earlier rule
// in this list — so a specific cause sits ABOVE the umbrella error it leads
// to (e.g. "gateway unreachable" above "matching failed").
// Keep patterns specific: a pattern that fires on a healthy log is worse than
// no rule at all. Patterns come from real report logs (2026-09/10) and from
// the messages the Python code prints.
// ─────────────────────────────────────────────────────────────────────────────
var RULES = [
  // ── Keys and credits ──
  { id: 'elevenlabs_key_missing', level: 'error',
    re: /No ElevenLabs API key configured|ElevenLabs API key unavailable|No ElevenLabs voice selected|--asr elevenlabs requires --elevenlabs-key/,
    title: 'ElevenLabs key is missing',
    why: 'Making or reading speech needs an ElevenLabs API key, and none is saved on this computer.',
    fix: 'Open Settings → Voices, paste the ElevenLabs key, press Save, then run again.' },
  { id: 'elevenlabs_credits', level: 'error',
    re: /quota_exceeded|exceeds your (?:character )?quota/i,
    title: 'ElevenLabs credits are used up',
    why: 'ElevenLabs refused the request because the account has no characters left this month.',
    fix: 'Top up the ElevenLabs plan (or use another key in Settings → Voices), then run again.' },
  { id: 'elevenlabs_key_rejected', level: 'error',
    re: /ElevenLabs rejected the API key \(401\)|Invalid or expired ElevenLabs API key \(401\)|\[11LABS\] HTTP 401/,
    title: 'ElevenLabs refused the key',
    why: 'The ElevenLabs key saved in Settings was not accepted — it is wrong, expired, or the account is out of credits.',
    fix: 'Copy the key again from elevenlabs.io → Profile → API keys, paste it in Settings → Voices, Save, and run again.' },
  { id: 'cartesia_key_missing', level: 'error',
    re: /No Cartesia API key configured/,
    title: 'Cartesia key is missing',
    why: 'The voice provider is set to Cartesia, but no Cartesia key is saved on this computer.',
    fix: 'Open Settings → Voices, paste the Cartesia key (or switch the voice provider back to ElevenLabs), Save, and run again.' },
  { id: 'cartesia_key_rejected', level: 'error',
    re: /Cartesia rejected the API key \(401\)/,
    title: 'Cartesia refused the key',
    why: 'The Cartesia key saved in Settings was not accepted.',
    fix: 'Copy the key again from the Cartesia dashboard, paste it in Settings → Voices, Save, and run again.' },
  { id: 'cartesia_credits', level: 'error',
    re: /out of credits \(402\)/,
    title: 'Cartesia credits are used up',
    why: 'Cartesia refused the request because the account has no credits left.',
    fix: 'Top up the Cartesia account, or switch the voice provider to ElevenLabs in Settings → Voices.' },

  // ── The AI server (gateway / Gemini) ──
  { id: 'llm_timeout_524', level: 'error',
    re: /returned HTTP 524|HTTP Error 524|\[GATEWAY\] HTTP 524/,
    title: 'The AI server took too long',
    why: 'The AI server gave up after about 100 seconds on one big request (error 524). This happens with long videos.',
    fix: 'Run again. If it fails again, cut the video into parts of about 10 minutes and dub each part.' },
  { id: 'llm_down_502', level: 'error',
    re: /returned HTTP 50[234]|HTTP Error 50[234]|\[GATEWAY\] HTTP 50[234]/,
    title: 'The AI server is down',
    why: 'The AI server that translates and matches was not answering (error 502/503/504). This is on our side, not your computer.',
    fix: 'Wait a few minutes and run again. If it keeps happening, reply to this email.' },
  { id: 'gemini_overloaded', level: 'error',
    re: /\[GEMINI\] 503 on .*overloaded|\[GEMINI\] All model variants failed/,
    title: 'Google\'s AI was overloaded',
    why: 'Google\'s Gemini service was too busy to answer.',
    fix: 'Wait a few minutes and run again.' },
  { id: 'llm_rate_limited', level: 'error',
    re: /returned HTTP 429|\[GATEWAY\] HTTP 429|\[GEMINI\] 429 on/,
    title: 'Too many AI requests at once',
    why: 'The AI server asked us to slow down (error 429) — too many requests in a short time.',
    fix: 'Wait a minute or two and run again.' },
  { id: 'gateway_unreachable', level: 'error',
    re: /\[GATEWAY\] Error: <urlopen error|No response from gateway|Cannot reach LLM endpoint|Lost the connection to the LLM endpoint/,
    title: 'Could not reach the AI server',
    why: 'This computer could not connect to the AI server. An office address (starting 172.18.) only works on the office network.',
    fix: 'Check the internet, connect to the office network or VPN if you use the office address, then run again.' },
  { id: 'cloudflare_1010', level: 'error',
    re: /error code: 1010|Cloudflare is blocking this client/,
    title: 'The AI server\'s firewall blocked this computer',
    why: 'Cloudflare, which protects the AI server, rejected the request from this computer.',
    fix: 'Update Fast Syncs (Settings → About → Update…) and run again. If it persists, reply to this email.' },
  { id: 'llm_key_rejected', level: 'error',
    re: /returned HTTP 40[13]\b|\[GATEWAY\] HTTP 40[13]\b|carried NO API key|Gateway API key is empty/,
    title: 'The AI server refused the key',
    why: 'The key saved for the AI server (Settings → Connection) is missing or not accepted.',
    fix: 'Open Settings → Connection, paste the correct key, Save, and run again.' },
  { id: 'llm_settings_wrong', level: 'error',
    re: /returned an HTML page, not JSON|is the gateway's admin console, not its API|Base URL must not include the endpoint path|OpenAI-compatible base URL is empty|backend=gateway requires SYNC_GEMINI_BASE_URL|backend=gateway but no gateway URL set/,
    title: 'The AI server address in Settings is wrong',
    why: 'The address saved in Settings → Connection is empty or points at the wrong page, so the AI could not be reached.',
    fix: 'Open Settings → Connection and put back the address the team gave you (it ends before "/v1/chat/completions"), Save, and run again.' },
  { id: 'llm_settings_missing', level: 'error',
    re: /LLM provider not usable:|LLM settings file not found|Model name is empty|Gemini API key is empty|backend=gateway requires --gemini-key|matcher=gemini requires --gemini-key|\[GEMINI\] No api_key for REST fallback/,
    title: 'AI settings are incomplete',
    why: 'The AI part of the settings (key, address or model) is not filled in on this computer.',
    fix: 'Open Settings → Connection, fill in the key and model, press Save, and run again.' },

  // ── Transcription / audio ──
  { id: 'elevenlabs_busy', level: 'error',
    re: /ElevenLabs rate limit hit \(429\)|\[11LABS\] HTTP 429|Cartesia rate limit hit \(429\)/,
    title: 'The voice service was busy',
    why: 'ElevenLabs/Cartesia asked us to slow down (error 429) — too many requests at the same time on this account.',
    fix: 'Wait a few minutes and run again. Avoid running two dubs at once on the same key.' },
  { id: 'transcription_failed', level: 'error',
    re: /ElevenLabs Scribe transcription failed after|\[ERROR\] Transcription produced NO text/,
    title: 'Turning the audio into text failed',
    why: 'ElevenLabs could not transcribe the audio — usually a dropped internet connection, or an ElevenLabs key/credit problem.',
    fix: 'Check the internet and the ElevenLabs key and credits (Settings → Voices), then run again.' },
  { id: 'voice_not_found', level: 'error',
    re: /ElevenLabs voice not found \(404\)|is not a valid ElevenLabs voice_id|Invalid ElevenLabs voice_id|Cartesia voice not found \(404\)|is not a Cartesia voice id/,
    title: 'The chosen voice does not exist',
    why: 'The voice picked in Settings is not on this voice account (deleted, or from another account).',
    fix: 'Open Settings → Voices, pick a voice from the list again, Save, and run again.' },
  { id: 'no_speech_found', level: 'error',
    re: /No speech regions detected in the English audio|No word data from ElevenLabs for the English audio/,
    title: 'No speech found in the English audio',
    why: 'The English audio that was given looks silent or has no speech the tool could find.',
    fix: 'Check the right English audio file was chosen and that it plays with speech, then run again.' },
  { id: 'audio_unreadable', level: 'error',
    re: /clips produced the SAME transcript|Could not extract chunk for item/,
    title: 'The audio file could not be read clip by clip',
    why: 'The audio format (for example .m4a / .mp4 / .aac) could not be cut into clips, so every clip got the same text.',
    fix: 'Convert the audio to .wav, import the .wav into REAPER instead, and run again.' },
  { id: 'file_locked', level: 'error',
    re: /Cannot write .* the file is locked by another program/,
    title: 'A file was in use by another program',
    why: 'The audio file the tool needed to write was still open in REAPER or another program.',
    fix: 'Remove that audio from the REAPER project (or close the other program), then run again.' },

  // ── The install itself ──
  { id: 'ffmpeg_missing', level: 'error',
    re: /ffmpeg not found|ffmpeg\/ffprobe not found/,
    title: 'ffmpeg is not installed',
    why: 'The dubbing part needs a helper program called ffmpeg to read and write audio, and it was not found.',
    fix: 'Run the update (Settings → About → Update…), which installs it, then restart REAPER and run again.' },
  { id: 'install_broken', level: 'error',
    re: /ModuleNotFoundError: No module named|Pipeline package is missing required symbols|dub_engine\.py not found at|sync_matcher\.py not found at|Prompt file\(s\) missing or empty for|Prompt file not found: prompts\/|Python produced no output for 90 seconds/,
    title: 'The Fast Syncs install is incomplete',
    why: 'Part of the program is missing on this computer — usually an update that did not finish.',
    fix: 'Run the update (Settings → About → Update…), let it finish, restart REAPER, and run again.' },

  // ── Matching (after the causes above, which explain it) ──
  { id: 'matching_failed', level: 'error',
    re: /0 clips matched — treating the run as FAILED|Gemini matching failed — sectioned AND batched|Gemini section matching failed twice/,
    title: 'Clips could not be matched',
    why: 'The step that pairs dubbed clips with English clips got no usable answer from the AI.',
    fix: 'Run again. If it fails again, reply to this email with the log attached.' },

  // ── Warnings: the run finished, but these explain a bad result ──
  { id: 'english_not_split', level: 'warn',
    re: /\bEN: [12] items \| DUB: \d{2,} items/,
    unless: /\[SPLIT\] EN clips for matching: \d+ → \d+/,
    title: 'The English track was one long clip',
    why: 'Auto Sync places each dubbed clip inside the English clip it matches. The English was one long clip, so all dubbed clips were packed together in one block — even if the log says they all matched.',
    fix: 'Cut the English track into sentences first (Dynamic Split), then run Auto Sync again. Newer versions do this cut automatically.' },
  { id: 'english_split_failed', level: 'warn',
    re: /LONG_EN_NOT_SPLIT/,
    title: 'A long English clip could not be cut automatically',
    why: 'An English clip was too long to match well, and the automatic cut into sentences was not possible for it.',
    fix: 'Cut the English track with Dynamic Split, or choose ElevenLabs for transcription, then run Auto Sync again.' },
  { id: 'dub_not_split', level: 'warn',
    re: /\bEN: \d{2,} items \| DUB: 1 items/,
    title: 'The dubbed track was one long clip',
    why: 'Auto Sync moves dubbed clips one by one. The dubbed track was a single clip, so there was nothing to move into place.',
    fix: 'Cut the dubbed track into sentences (Dynamic Split), then run Auto Sync again.' },
  { id: 'many_empty_clips', level: 'warn',
    re: /\[WARN\] Many empty transcripts/,
    title: 'Many clips had no speech in them',
    why: 'A lot of clips came back with no words — very short clips, breaths or noise.',
    fix: 'Delete the tiny clips (or re-split with a longer minimum length) and run again.' },
  { id: 'section_pieces', level: 'warn',
    re: /\[S2d\] Piece size: section\./,
    title: 'Speech was made in very long pieces',
    why: '"Dub pieces" is set to Section, so each piece of speech is 15–60 seconds long and cannot follow the English closely.',
    fix: 'Open Settings → Advanced → Dub pieces, choose Clause, then make the voice again.' },
  { id: 'pieces_too_long', level: 'warn',
    re: /longer than available space|would end .*→ Un ?sync/,
    title: 'Some dubbed lines are longer than the English',
    why: 'Some dubbed pieces take longer to say than the English they replace, so they run past it or were moved to the Un sync track.',
    fix: 'Shorten those lines and redo them in the Tools tab, or nudge them by hand.' },
  { id: 'some_unmatched', level: 'warn',
    re: /RESULT: \d+\/\d+ matched, [1-9]\d* unmatched/,
    title: 'Some clips were not matched',
    why: 'Some dubbed clips could not be paired with an English clip and were put on the Un sync track.',
    fix: 'Place those clips by hand (Sync Item), or check they actually contain speech.' },
  { id: 'lines_shortened', level: 'warn',
    re: /\[Splitter\] Shortening \d+ section/,
    title: 'The AI shortened some lines to fit',
    why: 'Some translated lines were too long for the English timing, so the AI shortened them.',
    fix: 'Check the shortened lines in the result and redo any that lost meaning in the Tools tab.' },
  { id: 'speech_reused', level: 'warn',
    re: /Reusing the speech from the previous run/,
    title: 'No new voice was made — last run\'s speech was reused',
    why: 'The script, voice and model were the same as last time, so the speech from the previous run was used again.',
    fix: 'To get a different voice, pick another voice in Settings → Voices (or change the text) and run again.' }
];

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) return reply_(false, 'empty');
    if (e.postData.contents.length > CONFIG.MAX_BODY_BYTES) return reply_(false, 'too large');

    var r = JSON.parse(e.postData.contents);
    if (String(r.team_code || '') !== CONFIG.TEAM_CODE) return reply_(false, 'bad team code');
    if (!underHourlyCap_()) return reply_(false, 'too many reports this hour, try later');

    // Work out the reason before taking the lock (the optional AI read takes a
    // few seconds). explain_ never throws, so it cannot lose the report.
    var d = explain_(r);

    var lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      var root = rootFolder_();
      var stamp = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd_HH-mm-ss');
      var label = [stamp, clean_(r.pipeline || r.kind), clean_(r.status), (r.stars ? r.stars + 'stars' : '')]
        .filter(String).join('_');
      var folder = root.createFolder(label);

      folder.createFile('report.txt', reportText_(r) + '\n\n' + reasonText_(d), MimeType.PLAIN_TEXT);
      var files = [];   // also attached to the email
      var logName = logFileName_(r.log_name);
      if (r.log_text) {
        folder.createFile(logName, String(r.log_text), MimeType.PLAIN_TEXT);
        files.push(Utilities.newBlob(String(r.log_text), 'text/plain', logName));
      }
      (r.attachments || []).slice(0, 5).forEach(function (a) {
        if (!a || !a.b64) return;
        var blob = Utilities.newBlob(Utilities.base64Decode(a.b64), null, clean_(a.name || 'attachment'));
        folder.createFile(blob);
        files.push(blob.copyBlob());
      });

      var sh = sheet_();
      sh.appendRow([new Date(), str_(r.app), str_(r.version), str_(r.pipeline), str_(r.status),
        r.stars || '', str_(r.contact), str_(r.message).slice(0, 2000), str_(r.os), folder.getUrl(),
        d.title]);

      // Every report is emailed (good ratings too); bad ones are flagged in the subject.
      var notify = CONFIG.NOTIFY_EMAIL || Session.getEffectiveUser().getEmail();
      if (notify.indexOf('@') > 0) {
        sendReportEmail_(notify, r, d, folder.getUrl(), logName, files, '');
      }
    } finally {
      lock.releaseLock();
    }
    return reply_(true, '');
  } catch (err) {
    return reply_(false, 'server error: ' + err);
  }
}

// A GET (someone opening the URL in a browser) reveals nothing.
function doGet() { return reply_(true, 'Fast Syncs inbox is running.'); }

// ── Reason for the error ─────────────────────────────────────────────────────

/** Rules first, then (if a key is set and the rules found nothing) the AI.
 *  Never throws: on any failure it falls back to a plain "could not tell". */
function explain_(r) {
  var d;
  try {
    d = diagnose_(r);
  } catch (err) {
    return { kind: 'unknown', title: 'Could not read the log', why: 'The inbox hit an error while reading the log: ' + err,
      fix: 'Open the attached log.', evidence: [], also: [], source: 'none' };
  }
  if (d.source !== 'none' || d.kind === 'nolog' || d.kind === 'cancelled') return d;
  try {
    var ai = aiDiagnose_(r, d);
    if (ai) return ai;
  } catch (err2) {
    d.note = 'AI read failed: ' + String(err2).slice(0, 200);
  }
  return d;
}

/** Pure: reads the report and its log, returns
 *  { kind, title, why, fix, evidence[], also[], source, id }. */
function diagnose_(r) {
  var log = String(r.log_text || '');
  var status = String(r.status || '').toLowerCase();
  var failed = /fail/.test(status);

  if (!log.trim()) {
    return {
      kind: 'nolog', source: 'none', evidence: [], also: [],
      title: 'No log was sent with this report',
      why: 'The box "Attach this run\'s log" was not ticked, so the reason cannot be read from the log.',
      fix: 'Send the report again from the same run with "Attach this run\'s log" ticked.'
    };
  }
  var lines = log.split(/\r?\n/);

  // 1. Known errors — the last line each rule matches.
  var hits = [];
  RULES.forEach(function (rule, order) {
    if (rule.unless && lines.some(function (ln) { return rule.unless.test(ln); })) return;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (rule.re.test(lines[i])) { hits.push({ rule: rule, at: i, order: order }); break; }
    }
  });
  hits.sort(function (a, b) {
    return levelRank_(a.rule.level) - levelRank_(b.rule.level) || a.order - b.order;
  });
  var titles = function (hs) { return unique_(hs.map(function (h) { return h.rule.title; })); };
  var happy = !failed && Number(r.stars) >= 4;
  // A failed run whose only matches are warnings failed for some other,
  // unknown reason — a warning must not be passed off as the cause. A happy
  // run (4–5 stars) has no "error" to explain; its matches are just notes.
  if (hits.length && !happy && !(failed && hits[0].rule.level !== 'error')) {
    var top = hits[0];
    return {
      kind: top.rule.level, source: 'rules', id: top.rule.id,
      title: top.rule.title, why: top.rule.why, fix: top.rule.fix,
      evidence: around_(lines, top.at),
      also: titles(hits.slice(1))
    };
  }
  var notes = titles(hits);

  // 2. Auto Sync prints its own "PROBLEMS FOUND" block with codes it already
  //    explains in words. A code with no rule above is still worth showing.
  var probs = [];
  lines.forEach(function (ln, i) {
    var m = /^\s*\[(ERROR|WARN)\]\s+([A-Z][A-Z0-9_]+):\s*(.+)$/.exec(ln);
    if (m) probs.push({ sev: m[1], code: m[2], msg: m[3], at: i });
  });
  probs.sort(function (a, b) { return (a.sev === 'ERROR' ? 0 : 1) - (b.sev === 'ERROR' ? 0 : 1); });
  var p = probs[0];
  if (p && !happy && !(failed && p.sev !== 'ERROR')) {
    return {
      kind: p.sev === 'ERROR' ? 'error' : 'warn', source: 'problems', id: p.code,
      title: 'Auto Sync reported ' + p.code,
      why: p.msg,
      fix: 'Follow what the message says. If it is unclear, reply to this email.',
      evidence: probs.slice(0, 6).map(function (q) { return trimLine_(lines[q.at]); }),
      also: notes
    };
  }

  // 3. Nothing known.
  if (/cancel|stop/.test(status)) {
    return {
      kind: 'cancelled', source: 'none', evidence: errorish_(lines), also: notes,
      title: 'The run was stopped before it finished',
      why: 'Someone pressed Stop, or REAPER was closed, while the run was going.',
      fix: 'Start the run again and let it finish.'
    };
  }
  if (failed) {
    return {
      kind: 'unknown', source: 'none', evidence: errorish_(lines), also: notes,
      title: 'Run failed — not a known error yet',
      why: 'The log does not match any error this inbox knows about.',
      fix: 'Read the log lines below. Once the cause is clear, add a rule for it to the inbox script.'
    };
  }
  return {
    kind: 'ok', source: 'none', evidence: happy ? [] : errorish_(lines), also: notes,
    title: happy ? 'No error — the run went well' : 'No error in the log',
    why: happy ? 'The run finished without an error and was rated ' + r.stars + ' of 5.'
      : 'The run finished without an error. The problem is in the result, not a crash — see the message.',
    fix: happy ? 'Nothing to do.' : 'Compare the result in the REAPER project with the message.'
  };
}

/** Optional: ask Gemini to read the log. Returns null when there is no key,
 *  the run looks fine, or the reply is unusable. */
function aiDiagnose_(r, d) {
  var props = PropertiesService.getScriptProperties();
  var key = props.getProperty('GEMINI_API_KEY');
  if (!key) return null;
  var lowStars = r.stars && r.stars <= 3;
  if (d.kind === 'ok' && !lowStars) return null;

  var lines = String(r.log_text || '').split(/\r?\n/);
  var tail = lines.slice(-CONFIG.AI_LOG_LINES).map(trimLine_).join('\n');
  var prompt = [
    'You are the support desk for "Fast Syncs", a REAPER add-on for dubbing English video into Indian languages.',
    '"Auto Sync" transcribes English and dubbed clips and moves each dubbed clip to the English clip it matches.',
    '"Dubbing" transcribes English, translates it, waits for a human review, then makes speech (ElevenLabs or Cartesia) and places it.',
    'A user sent the report below. Read the run log and say why the run went wrong.',
    'Write for the user: a dubbing artist, not a programmer. Plain words. No code, no file paths, no stack traces.',
    'If the log shows no error, say so and base the answer on their message.',
    'Reply ONLY with JSON: {"title": "<at most 8 words>", "why": "<1-2 sentences>", "fix": "<1-3 short steps they can do>", "sure": <0 to 1>}',
    '',
    'Pipeline: ' + str_(r.pipeline),
    'Result: ' + str_(r.status),
    'Stars: ' + str_(r.stars),
    'Their message: ' + str_(r.message),
    '',
    'Run log (last ' + CONFIG.AI_LOG_LINES + ' lines):',
    tail
  ].join('\n');

  var models = props.getProperty('AI_MODEL') ? [props.getProperty('AI_MODEL')] : CONFIG.AI_MODELS;
  for (var i = 0; i < models.length; i++) {
    var res = UrlFetchApp.fetch(
      'https://generativelanguage.googleapis.com/v1beta/models/' + encodeURIComponent(models[i]) + ':generateContent', {
        method: 'post', contentType: 'application/json', muteHttpExceptions: true,
        headers: { 'x-goog-api-key': key },
        payload: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: prompt }] }],
          generationConfig: { temperature: 0.2, maxOutputTokens: 1024, responseMimeType: 'application/json' }
        })
      });
    var code = res.getResponseCode();
    if (code === 404) continue;            // model retired — try the next one
    if (code !== 200) throw new Error('Gemini HTTP ' + code);
    var out = parseAiReply_(res.getContentText());
    if (!out) return null;
    return {
      kind: d.kind === 'ok' ? 'warn' : d.kind, source: 'ai', id: 'ai',
      title: out.title, why: out.why, fix: out.fix, sure: out.sure,
      evidence: d.evidence, also: []
    };
  }
  return null;
}

/** Pure: pulls {title, why, fix, sure} out of a Gemini generateContent reply. */
function parseAiReply_(body) {
  var j = JSON.parse(body);
  var parts = (((j.candidates || [])[0] || {}).content || {}).parts || [];
  var text = parts.map(function (p) { return p.text || ''; }).join('').trim();
  text = text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  var o = JSON.parse(text);
  if (!o || !o.title || !o.why) return null;
  return { title: String(o.title).slice(0, 120), why: String(o.why).slice(0, 800),
    fix: String(o.fix || '').slice(0, 800), sure: Number(o.sure) || 0 };
}

// ── Email ────────────────────────────────────────────────────────────────────

function sendReportEmail_(to, r, d, folderUrl, logName, files, subjectPrefix) {
  var mail = buildEmail_(r, d, folderUrl, logName);
  MailApp.sendEmail({
    to: to,
    subject: (subjectPrefix || '') + mail.subject,
    body: mail.text,
    htmlBody: mail.html,
    attachments: files,
    name: 'Fast Syncs Inbox'
  });
}

/** Pure: subject, plain-text and HTML body for one report. */
function buildEmail_(r, d, folderUrl, logName) {
  var bad = isBad_(r);
  var showTitle = d && (d.kind === 'error' || d.kind === 'warn' || d.kind === 'unknown');
  var subject = '[Fast Syncs] ' + (bad ? '⚠ ' : '') + (r.stars ? r.stars + '★ ' : '') +
    str_(r.pipeline || r.kind) + ' — ' + str_(r.status) + (showTitle ? ' — ' + d.title : '');

  var rows = detailRows_(r);
  var tail = String(r.log_text || '').split(/\r?\n/);
  while (tail.length && !tail[tail.length - 1].trim()) tail.pop();
  tail = tail.slice(-CONFIG.EMAIL_TAIL_LINES).map(trimLine_);
  var hasLog = !!String(r.log_text || '').trim();
  var how = howFound_(d);

  // Plain text (shown by mail apps that do not render HTML).
  var t = [];
  t.push('REPORT');
  rows.forEach(function (x) { t.push(pad_(x[0] + ':', 11) + x[1]); });
  t.push('', 'MESSAGE', str_(r.message) || '(no message)');
  t.push('', 'REASON FOR THE ERROR');
  t.push('Problem:    ' + d.title);
  t.push('Why:        ' + d.why);
  t.push('What to do: ' + d.fix);
  if (d.also && d.also.length) t.push('Also seen:  ' + d.also.join(' · '));
  t.push('(' + how + ')');
  if (d.evidence && d.evidence.length) t.push('', 'LOG LINES THAT SHOW IT', d.evidence.join('\n'));
  if (hasLog) t.push('', 'END OF THE LOG (last ' + tail.length + ' lines)', tail.join('\n'));
  t.push('', footerText_(hasLog, logName, folderUrl));

  // HTML.
  var h = [];
  h.push('<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#1f2937;max-width:720px">');
  h.push(sectionHead_('Report'));
  h.push('<table style="border-collapse:collapse">');
  rows.forEach(function (x) {
    h.push('<tr><td style="padding:2px 14px 2px 0;color:#6b7280;vertical-align:top">' + esc_(x[0]) +
      '</td><td style="padding:2px 0">' + esc_(x[1]) + '</td></tr>');
  });
  h.push('</table>');
  h.push(sectionHead_('Message'));
  h.push('<div style="border-left:3px solid #d1d5db;padding:4px 10px;white-space:pre-wrap">' +
    (esc_(str_(r.message)) || '<i>(no message)</i>') + '</div>');

  var box = { error: '#fef2f2;border-color:#fca5a5', warn: '#fffbeb;border-color:#fcd34d',
    unknown: '#f3f4f6;border-color:#d1d5db', ok: '#f0fdf4;border-color:#86efac' }[d.kind] ||
    '#f3f4f6;border-color:#d1d5db';
  h.push(sectionHead_(d.kind === 'ok' ? 'Result' : 'Reason for the error'));
  h.push('<div style="background:' + box + ';border-width:1px;border-style:solid;border-radius:6px;padding:10px 14px">');
  h.push('<div style="font-size:16px;font-weight:bold;margin-bottom:6px">' + esc_(d.title) + '</div>');
  h.push('<div style="margin-bottom:6px"><b>Why:</b> ' + esc_(d.why) + '</div>');
  h.push('<div><b>What to do:</b> ' + esc_(d.fix) + '</div>');
  if (d.also && d.also.length) {
    h.push('<div style="margin-top:6px;color:#6b7280"><b>Also seen in the log:</b> ' + esc_(d.also.join(' · ')) + '</div>');
  }
  h.push('<div style="margin-top:8px;color:#6b7280;font-size:12px">' + esc_(how) + '</div>');
  h.push('</div>');
  if (d.evidence && d.evidence.length) {
    h.push(sectionHead_('Log lines that show it'));
    h.push(pre_(d.evidence.join('\n')));
  }
  if (hasLog) {
    h.push(sectionHead_('End of the log (last ' + tail.length + ' lines)'));
    h.push(pre_(tail.join('\n')));
  }
  h.push('<p style="color:#6b7280;font-size:12px;margin-top:18px">' + esc_(footerText_(hasLog, logName, '')));
  if (folderUrl) h.push(' <a href="' + esc_(folderUrl) + '">Drive copy</a> (only the inbox owner can open it).');
  h.push('</p></div>');

  return { subject: subject, text: t.join('\n'), html: h.join('\n') };
}

function detailRows_(r) {
  var computer = [osName_(r.os), r.reaper ? 'REAPER ' + r.reaper : '', r.python ? 'Python ' + r.python : '']
    .filter(String).join(' · ');
  var rows = [
    ['From', str_(r.contact) || str_(r.name) || '(not given)'],
    ['Pipeline', str_(r.pipeline || r.kind)],
    ['Result', str_(r.status)],
    ['Rating', r.stars ? stars_(r.stars) : '(none)'],
    ['App', 'Fast Syncs v' + str_(r.version)],
    ['Project', str_(r.project)],
    ['Run time', duration_(r.duration_s)],
    ['Started', str_(r.started)],
    ['Computer', computer]
  ];
  return rows.filter(function (x) { return x[1]; });
}

function howFound_(d) {
  if (d.source === 'rules') return 'Found automatically: known error "' + d.id + '".';
  if (d.source === 'problems') return 'Found automatically: Auto Sync\'s own problem list.';
  if (d.source === 'ai') return 'Read by AI from the log' + (d.sure ? ' (' + Math.round(d.sure * 100) + '% sure)' : '') +
    ' — please check before forwarding.';
  return 'No known error matched.' + (d.note ? ' ' + d.note : '');
}

function footerText_(hasLog, logName, folderUrl) {
  var s = hasLog ? 'Full log attached: ' + logName + '.' : 'No log was attached to this report.';
  if (folderUrl) s += ' Drive copy: ' + folderUrl;
  return s;
}

// ── Report text saved in Drive ───────────────────────────────────────────────

function reportText_(r) {
  return [
    'App:      ' + str_(r.app) + ' v' + str_(r.version),
    'Pipeline: ' + str_(r.pipeline),
    'Result:   ' + str_(r.status),
    'Stars:    ' + str_(r.stars),
    'From:     ' + str_(r.contact),
    'Language: ' + str_(r.language),
    'Project:  ' + str_(r.project),
    'Duration: ' + str_(r.duration_s) + ' s',
    'Started:  ' + str_(r.started),
    'Computer: ' + str_(r.os) + ' · REAPER ' + str_(r.reaper) + ' · Python ' + str_(r.python),
    '',
    'Message:',
    str_(r.message)
  ].join('\n');
}

var REASON_MARK_ = '==== Reason for the error ====';

function reasonText_(d) {
  var t = [REASON_MARK_, 'Problem:    ' + d.title, 'Why:        ' + d.why, 'What to do: ' + d.fix];
  if (d.also && d.also.length) t.push('Also seen:  ' + d.also.join(' · '));
  t.push('(' + howFound_(d) + ')');
  if (d.evidence && d.evidence.length) t.push('', 'Log lines:', d.evidence.join('\n'));
  return t.join('\n');
}

/** Pure: rebuilds the report fields from a saved report.txt (old or new format). */
function parseReportText_(text) {
  var r = {};
  var body = String(text || '').split(REASON_MARK_)[0];
  var parts = body.split(/\nMessage:\n/);
  parts[0].split(/\r?\n/).forEach(function (ln) {
    var m = /^(\w+):\s*(.*)$/.exec(ln);
    if (m) r[m[1].toLowerCase()] = m[2].trim();
  });
  var out = {
    app: 'Fast Syncs', version: (/v(\S+)$/.exec(r.app || '') || [])[1] || '',
    pipeline: r.pipeline || '', status: r.result || '', stars: Number(r.stars) || 0,
    contact: r.from || '', language: r.language || '', project: r.project || '',
    duration_s: parseFloat(r.duration) || 0, started: r.started || '',
    message: (parts[1] || '').trim()
  };
  var c = (r.computer || '').split(' · ');
  out.os = c[0] || '';
  out.reaper = (c[1] || '').replace(/^REAPER\s*/, '');
  out.python = (c[2] || '').replace(/^Python\s*/, '');
  return out;
}

// ── Re-check reports that arrived before this version ────────────────────────

/** Run from the editor: re-reads the newest report in the Drive folder and
 *  emails it again in the new format, with the reason. */
function explainLatest() {
  var newest = null;
  var it = rootFolder_().getFolders();
  while (it.hasNext()) {
    var f = it.next();
    if (!newest || f.getDateCreated() > newest.getDateCreated()) newest = f;
  }
  if (!newest) throw new Error('No reports in the folder yet.');
  explainFolder(newest.getId());
}

/** Re-checks one report folder (its Drive id or URL) and emails it again. */
function explainFolder(idOrUrl) {
  var id = String(idOrUrl || '').replace(/^.*\/folders\//, '').replace(/[?#].*$/, '');
  var folder = DriveApp.getFolderById(id);
  var r = {}, logName = '', logText = '', files = [];
  var it = folder.getFiles();
  while (it.hasNext()) {
    var f = it.next();
    var name = f.getName();
    if (name === 'report.txt') {
      r = parseReportText_(f.getBlob().getDataAsString('UTF-8'));
    } else if (/\.txt$/i.test(name)) {
      logName = name;
      logText = f.getBlob().getDataAsString('UTF-8');
      files.push(f.getBlob());
    } else {
      files.push(f.getBlob());
    }
  }
  r.log_name = logName;
  r.log_text = logText;
  var d = explain_(r);
  var notify = CONFIG.NOTIFY_EMAIL || Session.getEffectiveUser().getEmail();
  sendReportEmail_(notify, r, d, folder.getUrl(), logName, files, '(re-check) ');
  Logger.log(d.title + ' — ' + d.why);
}

// ── Small helpers ────────────────────────────────────────────────────────────

function isBad_(r) {
  return !!((r.stars && r.stars <= 3) || /fail/i.test(String(r.status || '')) || r.kind === 'feedback');
}

function levelRank_(level) { return level === 'error' ? 0 : 1; }

/** The matched line plus one line before and two after — tracebacks put the
 *  useful part on the next line. */
function around_(lines, at) {
  var out = [];
  for (var i = Math.max(0, at - 1); i <= Math.min(lines.length - 1, at + 2); i++) {
    if (lines[i].trim()) out.push(trimLine_(lines[i]));
  }
  return out;
}

/** The last few lines that look like an error, in log order. */
function errorish_(lines) {
  var rx = /Traceback|Error\b|ERROR|FAILED|Failed|failed|Exception|HTTP [45]\d\d|\b[45]\d\d (?:Client|Server) Error|✗|❌/;
  var out = [];
  for (var i = lines.length - 1; i >= 0 && out.length < 8; i--) {
    var ln = trimLine_(lines[i]);
    if (rx.test(ln) && out.indexOf(ln) < 0) out.unshift(ln);
  }
  return out;
}

function trimLine_(s) {
  s = String(s || '').replace(/\s+$/, '');
  return s.length > 300 ? s.slice(0, 300) + ' …' : s;
}

function unique_(a) {
  var out = [];
  a.forEach(function (x) { if (out.indexOf(x) < 0) out.push(x); });
  return out;
}

function logFileName_(name) {
  var n = clean_(name || 'run_log');
  return /\.txt$/i.test(n) ? n : n + '.txt';
}

function stars_(n) {
  n = Math.max(0, Math.min(5, Number(n) || 0));
  return new Array(n + 1).join('★') + new Array(6 - n).join('☆') + ' (' + n + ' of 5)';
}

function duration_(s) {
  s = Math.round(Number(s) || 0);
  if (!s) return '';
  var m = Math.floor(s / 60);
  return m ? m + ' min ' + (s % 60) + ' s' : s + ' s';
}

function osName_(os) {
  os = String(os || '');
  if (/^win/i.test(os)) return 'Windows';
  if (/darwin|mac/i.test(os)) return 'Mac';
  return os;
}

function sectionHead_(t) {
  return '<div style="font-size:12px;font-weight:bold;letter-spacing:.06em;text-transform:uppercase;' +
    'color:#6b7280;margin:18px 0 6px">' + esc_(t) + '</div>';
}

function pre_(t) {
  return '<pre style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:6px;padding:8px 10px;' +
    'font-size:12px;line-height:1.4;white-space:pre-wrap;word-break:break-word;margin:0">' + esc_(t) + '</pre>';
}

function pad_(s, n) { while (s.length < n) s += ' '; return s; }

function esc_(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function reply_(ok, error) {
  return ContentService.createTextOutput(JSON.stringify({ ok: ok, error: error }))
    .setMimeType(ContentService.MimeType.JSON);
}

function str_(v) { return v === undefined || v === null ? '' : String(v); }
function clean_(v) { return String(v || '').replace(/[^\w.\- ]+/g, '').slice(0, 80) || 'x'; }

function rootFolder_() {
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('FOLDER_ID');
  if (id) { try { return DriveApp.getFolderById(id); } catch (e) {} }
  var f = DriveApp.createFolder(CONFIG.FOLDER_NAME);
  props.setProperty('FOLDER_ID', f.getId());
  return f;
}

function sheet_() {
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('SHEET_ID');
  var ss = null;
  if (id) { try { ss = SpreadsheetApp.openById(id); } catch (e) {} }
  if (!ss) {
    ss = SpreadsheetApp.create('Fast Syncs Reports — index');
    ss.getSheets()[0].appendRow(['Received', 'App', 'Version', 'Pipeline', 'Result', 'Stars',
      'From', 'Message', 'OS', 'Files', 'Reason']);
    DriveApp.getFileById(ss.getId()).moveTo(rootFolder_());
    props.setProperty('SHEET_ID', ss.getId());
  }
  var sh = ss.getSheets()[0];
  // Sheets made before the Reason column existed get its header once.
  if (!sh.getRange(1, 11).getValue()) sh.getRange(1, 11).setValue('Reason');
  return sh;
}

function underHourlyCap_() {
  var cache = CacheService.getScriptCache();
  var key = 'n_' + Utilities.formatDate(new Date(), 'UTC', 'yyyyMMddHH');
  var n = Number(cache.get(key) || 0) + 1;
  cache.put(key, String(n), 3700);
  return n <= CONFIG.MAX_PER_HOUR;
}

/** Run once from the editor to create the folder + sheet and grant access.
 *  Run it again after pasting a new version of this script, so Google asks
 *  for any new permission (this version adds "connect to an external
 *  service", used only for the optional AI read). */
function setup() {
  rootFolder_();
  sheet_();
  UrlFetchApp.getRequest('https://generativelanguage.googleapis.com/');  // triggers the permission prompt; sends nothing
  Logger.log('Folder: ' + rootFolder_().getUrl());
}
