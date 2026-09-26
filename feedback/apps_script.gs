/**
 * Fast Syncs team inbox — Google Apps Script web app.
 *
 * Receives the in-app "Send report" / "Send Feedback" posts and:
 *   1. saves the run log (and any screenshots) as files in one private
 *      Google Drive folder, one sub-folder per report,
 *   2. adds a row to a Google Sheet (date, stars, pipeline, message, link),
 *   3. emails the owner for every report with 1-3 stars or an error.
 *
 * The web app can only ADD reports. Nothing it returns reveals other reports,
 * so its URL is safe to ship inside the app. It rejects posts without the
 * team code, oversized posts, and floods (per-hour cap).
 *
 * Setup: see feedback/SETUP.md. Fill the three CONFIG values below.
 */

var CONFIG = {
  TEAM_CODE: 'CHANGE-ME',          // same value as "team_code" in feedback_config.json
  NOTIFY_EMAIL: '',                // who gets an email for bad runs ('' = the script's owner)
  FOLDER_NAME: 'Fast Syncs Reports',
  MAX_BODY_BYTES: 12 * 1024 * 1024, // reject anything bigger (log tail is ~1.5 MB)
  MAX_PER_HOUR: 60                  // flood guard across all senders
};

function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) return reply_(false, 'empty');
    if (e.postData.contents.length > CONFIG.MAX_BODY_BYTES) return reply_(false, 'too large');

    var r = JSON.parse(e.postData.contents);
    if (String(r.team_code || '') !== CONFIG.TEAM_CODE) return reply_(false, 'bad team code');
    if (!underHourlyCap_()) return reply_(false, 'too many reports this hour, try later');

    var lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      var root = rootFolder_();
      var stamp = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd_HH-mm-ss');
      var label = [stamp, clean_(r.pipeline || r.kind), clean_(r.status), (r.stars ? r.stars + 'stars' : '')]
        .filter(String).join('_');
      var folder = root.createFolder(label);

      var summary = [
        'App:      ' + str_(r.app) + ' v' + str_(r.version),
        'Pipeline: ' + str_(r.pipeline),
        'Result:   ' + str_(r.status),
        'Stars:    ' + str_(r.stars),
        'From:     ' + str_(r.contact),
        'Project:  ' + str_(r.project),
        'Duration: ' + str_(r.duration_s) + ' s',
        'Computer: ' + str_(r.os) + ' · REAPER ' + str_(r.reaper) + ' · Python ' + str_(r.python),
        '',
        'Message:',
        str_(r.message)
      ].join('\n');
      folder.createFile('report.txt', summary, MimeType.PLAIN_TEXT);
      if (r.log_text) {
        folder.createFile(clean_(r.log_name || 'run_log') + '.txt', String(r.log_text), MimeType.PLAIN_TEXT);
      }
      (r.attachments || []).slice(0, 5).forEach(function (a) {
        if (!a || !a.b64) return;
        var blob = Utilities.newBlob(Utilities.base64Decode(a.b64), null, clean_(a.name || 'attachment'));
        folder.createFile(blob);
      });

      sheet_().appendRow([new Date(), str_(r.app), str_(r.version), str_(r.pipeline), str_(r.status),
        r.stars || '', str_(r.contact), str_(r.message).slice(0, 2000), str_(r.os), folder.getUrl()]);

      var bad = (r.stars && r.stars <= 3) || /fail/i.test(String(r.status || '')) || r.kind === 'feedback';
      var notify = CONFIG.NOTIFY_EMAIL || Session.getEffectiveUser().getEmail();
      if (bad && notify.indexOf('@') > 0) {
        MailApp.sendEmail(notify,
          '[Fast Syncs] ' + (r.stars ? r.stars + '★ ' : '') + str_(r.pipeline || r.kind) + ' — ' + str_(r.status),
          summary + '\n\nFiles: ' + folder.getUrl());
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
      'From', 'Message', 'OS', 'Files']);
    DriveApp.getFileById(ss.getId()).moveTo(rootFolder_());
    props.setProperty('SHEET_ID', ss.getId());
  }
  return ss.getSheets()[0];
}

function underHourlyCap_() {
  var cache = CacheService.getScriptCache();
  var key = 'n_' + Utilities.formatDate(new Date(), 'UTC', 'yyyyMMddHH');
  var n = Number(cache.get(key) || 0) + 1;
  cache.put(key, String(n), 3700);
  return n <= CONFIG.MAX_PER_HOUR;
}

/** Run once from the editor to create the folder + sheet and grant access. */
function setup() {
  rootFolder_();
  sheet_();
  Logger.log('Folder: ' + rootFolder_().getUrl());
}
