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

Changing the script later: **Deploy → Manage deployments → edit → New
version**. The URL stays the same.

Note: the repo is public, so the URL and team code are visible to anyone who
looks. The worst anyone can do with them is post junk reports; the script caps
size and reports per hour. If it is ever abused, change `TEAM_CODE` in both
places.
