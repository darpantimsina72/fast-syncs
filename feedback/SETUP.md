# Team inbox setup (one time, ~5 minutes)

In-app reports go to a Google Apps Script in **your** Google account. It saves
each report in a private Drive folder, adds a row to a Sheet, and emails you
for bad runs. It can only add reports — nobody can read reports through it.

1. Open <https://script.google.com> signed in as the account that should own
   the reports → **New project**. Name it `Fast Syncs Inbox`.
2. Delete the sample code and paste all of `feedback/apps_script.gs`.
3. At the top, set:
   - `TEAM_CODE` — any long random word, e.g. `fs-7Qk2-mango-41`.
   - `NOTIFY_EMAIL` — where "bad run" emails go (leave empty = the account that owns the script).
4. Choose the `setup` function in the toolbar → **Run** → allow the access it
   asks for (Drive, Sheets, send email as you). This creates the
   `Fast Syncs Reports` folder and its index Sheet.
5. **Deploy → New deployment → type: Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**  (needed so the app can post without a login)
   → Deploy → copy the **Web app URL** (ends in `/exec`).
6. In the repo, fill `feedback_config.json`:
   ```json
   { "endpoint": "https://script.google.com/macros/s/…/exec",
     "team_code": "fs-7Qk2-mango-41" }
   ```
   Commit and release it. Every install gets it with the next update; reports
   that were waiting on people's PCs are sent with their next report.

Changing the script later:

1. Paste the new `feedback/apps_script.gs` over the old code, **but keep your
   own `TEAM_CODE` line** — a wrong code makes the inbox refuse every report.
2. Choose `setup` → **Run** once, and allow any new access Google asks for.
   (Skipping this can make every report fail until someone does.)
3. **Deploy → Manage deployments → edit → New version**. The URL stays the same.

## The reason in each email

Every email ends with a **Reason for the error** box: what went wrong, why,
and what to do — written so the email can be forwarded to the person who sent
the report. Below it are the log lines that show it, the end of the log, and
the full log as an attachment.

- Known errors are recognised by the `RULES` list near the top of the script.
  When a new kind of error turns up, add a rule (an exact piece of the log
  line, plus three plain sentences) and run `node tests/test_inbox_reason.js`.
- **Optional AI read** for errors no rule knows: in the Apps Script editor,
  **Project Settings → Script properties → Add**, name `GEMINI_API_KEY`,
  value = a Google AI Studio key. Without it, unknown errors still show the
  log lines that look like errors. Never put the key in the script itself —
  this repo is public.
- To see an old report in the new format, choose `explainLatest` → **Run**:
  it re-sends the newest report as an email with the reason.

Note: the repo is public, so the URL and team code are visible to anyone who
looks. The worst anyone can do with them is post junk reports; the script caps
size and reports per hour. If it is ever abused, change `TEAM_CODE` in both
places.
