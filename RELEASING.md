# Releasing

## The problem this solves

Until now there was no such thing as "a version" of fast-syncs. The updater
downloaded whatever was last committed to `main`, so users could pick up
half-finished work, and if something broke there was nothing to go back to —
no tags, no releases, nothing to reinstall.

Now `main` is where work happens and `production` is what people run.

```
  main ──────●───────●───────●───────●────────────►   development
              \               \
               \               \  merge = ship
                ▼               ▼
  production ───●───────────────●──────────────────►   what users get
                │               │
             v0.13.0         v0.14.0                   tag + GitHub Release
                                                       (created automatically)
```

Nothing reaches a user until you merge into `production`.

---

## Cutting a release

1. **Bump the version in two places on `main`** — they are checked against each
   other and the release fails if they disagree:
   - `VERSION` — a single line, e.g. `0.14.0`
   - the `-- @version` header at the top of `auto_sync_pipeline.lua`

2. **Merge `main` into `production`.**

   ```bash
   git checkout production
   git merge --ff-only main
   git push origin production
   ```

3. **That's it.** [`.github/workflows/release.yml`](.github/workflows/release.yml)
   takes over and:
   - verifies `VERSION` and `@version` agree,
   - tags the commit `v0.14.0`,
   - builds `fast-syncs.zip` (the product only — no `server/`, `.github/`,
     `.claude/` or agent docs),
   - checks the archive actually contains the entrypoints,
   - publishes a GitHub Release with notes generated from the merged PRs.

Watch it under the repo's **Actions** tab. The run summary tells you what
happened either way.

### If you push to `production` without bumping the version

Nothing is published and **the job does not fail** — a docs-only push to
production is legitimate. The summary says "No release cut" and explains why.
Bump `VERSION` and merge again when you actually want to ship.

---

## How users receive it

The **Update…** button (and `update.sh` / `update.bat`) now downloads:

```
https://github.com/darpantimsina72/fast-syncs/releases/latest/download/fast-syncs.zip
```

That URL is stable and always resolves to the newest *published release*.
Settings, both `venv/` folders and the `.direct-mode` marker are outside the
archive, so they survive an update exactly as before.

**Git-clone installs:** `update.sh` / `update.bat` still run `git pull` on
whatever branch the clone is on. If you cloned before this change you are on
`main` and will keep tracking development builds — switch with
`git checkout production`.

---

## Rolling back

Something shipped broken? Two ways, no repo access needed:

**Any user, right now:** download the previous `fast-syncs.zip` from the
[Releases page](https://github.com/darpantimsina72/fast-syncs/releases) and
unzip it over the folder. Settings and `venv/` are preserved.

**Scripted:**

```bash
FAST_SYNCS_ZIP_URL=https://github.com/darpantimsina72/fast-syncs/releases/download/v0.13.0/fast-syncs.zip bash update.sh
```

**As the maintainer**, if a release is bad: fix forward. Bump to the next
patch version on `main` and merge to `production` again. Don't delete or move
a published tag — anyone who already installed it has that version, and moving
the tag makes their install unreproducible.

---

## Next step: ReaPack distribution

This is deliberately **not** enabled yet, because it needs one decision that
should be yours. Everything above works without it.

[ReaPack](https://reapack.com) is REAPER's built-in package manager. Users
import one URL and then get, natively:

| What you wanted | How ReaPack does it |
|---|---|
| Distribute to everyone | *Import repositories* → paste one URL → *Browse packages* |
| Keep it updated | *Synchronize packages* updates everything, including this |
| Roll back | Right-click the package → **Versions…** → pick any earlier version |
| — also — | **Pin current version** freezes a machine on a known-good build |

It also fixes a real bug in the current ZIP flow: **ReaPack removes files that
were deleted upstream.** The ZIP overlay only ever adds and overwrites, so
files you delete stay on users' disks forever and their install slowly drifts
into a state nobody else has.

### The decision to make

ReaPack installs a package's files into REAPER's own resource folder
(`Scripts/…`). For this project that means the Python engine, `requirements.txt`
and the setup scripts land there too, and `setup.sh` would create `venv/`
inside REAPER's Scripts directory.

That works — `get_script_dir()` resolves relative to the script's real
location, so the Lua finds its Python siblings wherever they are — but it is an
unusual place for a virtualenv, and it is worth deciding on purpose rather than
discovering later.

Two shapes:

- **Ship everything through ReaPack.** One package, ~100 files. Cleanest for
  users: install, run, and the script offers to build the Python environment.
  The venv lives under `Scripts/fast-syncs/venv`.
- **Ship only the scripts through ReaPack** and keep the Python engine on the
  ZIP/release flow. Smaller ReaPack package, but two update paths to keep in
  step — which is the kind of split that causes the "half-updated install"
  problems this repo already has.

The first is probably right, but it is a one-way door for users' folder
layouts, so it should be a deliberate call.

### What implementing it involves

1. Extend the `@provides` header in `auto_sync_pipeline.lua` to list the files
   that ship alongside it (ReaPack supports glob patterns).
2. Run [`reapack-index`](https://github.com/cfillion/reapack-index) in CI to
   generate `index.xml`. It walks git history and creates a package version for
   each commit where `@version` changed — so it needs `fetch-depth: 0`, which
   the release workflow already uses.
3. Commit `index.xml` to `production` and give users the raw URL to import.
4. Verify against a real ReaPack install before announcing it. The header
   semantics are worth testing rather than trusting — this document has not
   been validated against a live install.

**What ReaPack still will not do:** create the Python virtualenv or install
ffmpeg. `setup.sh` / `setup.bat` remain the one-time step. The script already
offers to run setup when it notices the venv is missing, so the flow is
"install via ReaPack → run → say yes once".
