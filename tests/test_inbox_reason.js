#!/usr/bin/env node
/*
 * Offline checks for the team inbox's "reason for the error" (feedback/apps_script.gs).
 *
 * The Apps Script cannot run here, but the parts that read a log and build
 * the email are plain JavaScript with no Google services, so they are loaded
 * into a sandbox and checked against log lines copied from real reports.
 *
 * Guards:
 *   1. Each known error in a real log gets its own reason, not a generic one.
 *   2. A healthy log matches no error rule (a rule that fires on a good run
 *      would put a wrong reason in front of a customer).
 *   3. No log / stopped run / unknown failure / Auto Sync problem list each
 *      get a sensible answer, never a crash.
 *   4. The email carries the details, the message, the reason, the log lines
 *      and the end of the log, with HTML escaped.
 *   5. An old-format report.txt still parses (for re-checking old reports).
 *
 * Run:  node tests/test_inbox_reason.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'feedback', 'apps_script.gs'), 'utf8');
const box = {};
vm.createContext(box);
vm.runInContext(src, box, { filename: 'apps_script.gs' });

let fails = 0;
function check(name, cond) {
  console.log((cond ? 'PASS  ' : 'FAIL  ') + name);
  if (!cond) fails++;
}

function report(status, log, extra) {
  return Object.assign({ app: 'Fast Syncs', version: '0.15.9', pipeline: 'Auto Sync', status: status,
    stars: 1, contact: 'tester (Nepali)', message: 'did not work', os: 'win32', log_text: log }, extra || {});
}

// ── 1 + 2. Known errors, from real logs ─────────────────────────────────────
const CASES = require('./inbox_reason_cases.js');
CASES.forEach(function (c) {
  const d = box.diagnose_(report(c.status || 'failed', c.log, c.extra));
  if (c.expect === null) {
    check(c.name + ' → no error rule fires', d.source !== 'rules');
  } else {
    check(c.name + ' → ' + c.expect + ' (got ' + d.id + ')', d.source === 'rules' && d.id === c.expect);
    check(c.name + ' → evidence quotes the log', d.evidence.length > 0);
  }
});

// Every rule is well formed: no /g (stateful .test), words for all three parts.
// (Regexes made inside the sandbox are not `instanceof RegExp` out here.)
const rules = vm.runInContext('RULES', box);
rules.forEach(function (r) {
  check('rule ' + r.id + ' is well formed',
    !!(r.re && typeof r.re.test === 'function' && !r.re.global));
  check('rule ' + r.id + ' has title/why/fix/level',
    !!(r.title && r.why && r.fix && (r.level === 'error' || r.level === 'warn')));
});
const ids = rules.map(function (r) { return r.id; });
check('rule ids are unique', new Set(ids).size === ids.length);

// ── 3. The no-rule paths ────────────────────────────────────────────────────
let d = box.diagnose_(report('failed', ''));
check('no log → asks for the log', d.kind === 'nolog' && /Attach this run/.test(d.fix));

d = box.diagnose_(report('cancelled', 'STEP 1\nworking...\n'));
check('stopped run → cancelled', d.kind === 'cancelled');

d = box.diagnose_(report('failed', 'STEP 1\nTraceback (most recent call last):\n  File "x.py", line 3\nZeroDivisionError: division by zero\n'));
check('unknown failure → unknown, quotes the traceback', d.kind === 'unknown' &&
  d.evidence.some(function (l) { return /ZeroDivisionError/.test(l); }));

d = box.diagnose_(report('ok', [
  '============================================================',
  '  PROBLEMS FOUND: 2',
  '============================================================',
  '  [WARN] SOME_NEW_CODE: Three clips were left on the Un sync track.',
  '  [ERROR] ANOTHER_NEW_CODE: Nothing could be matched.',
  '============================================================'].join('\n')));
check('Auto Sync problem list → its ERROR is the reason', d.source === 'problems' &&
  d.id === 'ANOTHER_NEW_CODE' && /Nothing could be matched/.test(d.why));

d = box.diagnose_(report('ok', 'STEP 1\nSTEP 2\nSTEP 3\nSTEP 4\nRESULT: 12/12 matched\n', { stars: 2 }));
check('clean log, low stars → "no error in the log"', d.kind === 'ok');

// ── 4. The email ────────────────────────────────────────────────────────────
const r = report('failed', 'line one\n<b>tag</b> & stuff\nTraceback (most recent call last):\nValueError: bad\n',
  { message: 'voice <did not> come', project: 'My Video', duration_s: 252, reaper: '7.22', python: '3.12.1' });
d = box.diagnose_(r);
const m = box.buildEmail_(r, d, 'https://drive.google.com/drive/folders/abc', 'run.txt');
check('subject flags a bad run', /^\[Fast Syncs\] ⚠ 1★ Auto Sync — failed/.test(m.subject));
check('html escapes the log', m.html.indexOf('<b>tag</b>') < 0 && m.html.indexOf('&lt;b&gt;tag&lt;/b&gt;') >= 0);
check('html escapes the message', m.html.indexOf('voice &lt;did not&gt; come') >= 0);
check('email has details', /tester \(Nepali\)/.test(m.text) && /4 min 12 s/.test(m.text) && /Windows · REAPER 7.22/.test(m.text));
check('reason sits below the details and above the log',
  m.text.indexOf('REPORT') < m.text.indexOf('REASON FOR THE ERROR') &&
  m.text.indexOf('REASON FOR THE ERROR') < m.text.indexOf('END OF THE LOG'));
check('email names the attached log', /Full log attached: run\.txt/.test(m.text));
check('email links the Drive copy', m.html.indexOf('href="https://drive.google.com/drive/folders/abc"') >= 0);

const longLog = Array.from({ length: 500 }, function (_, i) { return 'line ' + i; }).join('\n');
const m2 = box.buildEmail_(report('ok', longLog, { stars: 5 }), box.diagnose_(report('ok', longLog, { stars: 5 })), '', 'x.txt');
check('only the last 40 lines are printed', m2.text.indexOf('line 459') < 0 && m2.text.indexOf('line 460') >= 0 &&
  m2.text.indexOf('line 499') >= 0);
check('a 5-star ok run is not flagged', m2.subject.indexOf('⚠') < 0);

check('stars_ renders', box.stars_(2) === '★★☆☆☆ (2 of 5)');
check('logFileName_ does not double .txt', box.logFileName_('a.txt') === 'a.txt' && box.logFileName_('a') === 'a.txt');

// AI reply parsing (the AI itself is never called here).
const ai = box.parseAiReply_(JSON.stringify({ candidates: [{ content: { parts: [{ text:
  '```json\n{"title":"Key expired","why":"The ElevenLabs key was refused.","fix":"Paste a new key.","sure":0.8}\n```' }] } }] }));
check('AI reply parsed', ai && ai.title === 'Key expired' && ai.sure === 0.8);

// ── 5. Old report.txt still parses ──────────────────────────────────────────
const old = box.parseReportText_([
  'App:      Fast Syncs v0.15.8',
  'Pipeline: Dubbing — own script',
  'Result:   failed',
  'Stars:    1',
  'From:     pratima (Nepali)',
  'Project:  test',
  'Duration: 41 s',
  'Computer: win32 · REAPER 7.27 · Python 3.12.4',
  '',
  'Message:',
  'dubbing voice did not came'].join('\n'));
check('old report.txt parses', old.version === '0.15.8' && old.pipeline === 'Dubbing — own script' &&
  old.status === 'failed' && old.stars === 1 && old.os === 'win32' && old.reaper === '7.27' &&
  old.message === 'dubbing voice did not came');
const again = box.parseReportText_(box.reportText_(old) + '\n\n' + box.reasonText_(box.diagnose_(report('failed', ''))));
check('new report.txt round-trips without the reason leaking into the message',
  again.message === 'dubbing voice did not came' && again.language === '');

console.log(fails ? '\nRED: ' + fails + ' check(s) failed' : '\nGREEN: all checks passed');
process.exit(fails ? 1 : 0);
