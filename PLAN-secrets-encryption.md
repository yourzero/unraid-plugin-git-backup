# git-crypt for the Unraid config-backup repo — implementation record

**Derived from:** `HANDOFF-secrets-encryption.md`
**Executed:** 28–29 July 2026
**Decisions taken:** history = **(b) `filter-repo` purge** · rotation = **deferred** ·
scope = **local safety backup first, then content sweep** · slimming = **purge vendored bloat** ·
transcripts = **encrypt, not exclude** · bundle **I1 + I10** into the config change.

| Phase | Status |
|---|---|
| 0. Safety backup of the repo | ✅ done |
| 1. `git-crypt` binary, persistent + on PATH | ✅ done |
| 2. Secret sweep + `.gitattributes` | ✅ done |
| 3. `.gitignore` slimming (72,407 files) | ✅ done |
| 4. History purge with `filter-repo` | ✅ done (**three passes — see §5**) |
| 5. `git-crypt` enabled + key escrowed | ✅ done · ⚠️ **off-box key copy still outstanding** |
| 6. The guard (two layers) | ✅ done + failure-tested |
| 7. Verification 1–6 | ✅ done |
| 8. Live cron run | ✅ full `backup.sh` run verified clean (exit 0, 0 errors) |
| 9. Plugin release (code changes) | ⬜ not started — config-only fixes are already live |
| 10. Rotation | ⏸ deferred by decision |

---

## 1. Outcome

| Metric | Before | After |
|---|---|---|
| Tracked files | 145,420 | 73,014 |
| `.git` size | 1.6 GB | ~315 MB |
| Working tree | 4.3 GB | ~940 MB |
| Commits | 27 | 29 (history preserved, rewritten) |
| Plaintext credentials on GitHub | **yes, all 27 commits** | **none** |

48 credential files plus 1,190 Claude Code transcript files are encrypted at rest. Verified by
fresh clone from GitHub (§7).

---

## 2. Corrections to the handoff (verified)

- The stale plugin-source path CLAUDE.md warned about was **already fixed**; source is
  `/mnt/user/development/unraid-plugin-git-backup`.
- No `gcc`/`g++`/`make` on the box, but `docker` is present — that is how git-crypt got built.
- **The guard did not need a plugin release.** `backup.sh:521 git_commit_and_push()` runs
  `git add -A` → `git commit` → `git push`, and a failing `pre-commit` hook makes the commit
  non-zero, which `backup.sh:545` already logs and returns on — so the push never happens.
  Likewise the I1/I10 fixes are pure `git-backup.cfg` edits and are **live now**. Only the
  hardening in §8 needs a release.

## 3. Phase 1 — `git-crypt` binary

Built **0.7.0 static musl** in Alpine via Docker. Three gotchas, all real, all now solved:

1. `crypto-openssl-10.cpp` is guarded by `#if !defined(OPENSSL_API_COMPAT)`. Alpine's OpenSSL 3
   doesn't define it, so the **OpenSSL 1.0 path compiled** and failed on `HMAC_cleanup`.
   Fix: `-DOPENSSL_API_COMPAT=0x10100000L`. Installing `pkgconf` is *not* the fix — the Makefile
   compiles both backends unconditionally and lets the preprocessor choose.
2. The Makefile does `LDFLAGS += -lcrypto`, but setting `LDFLAGS` **on the make command line makes
   it immutable**, silently dropping `-lcrypto` → undefined references. Pass it yourself.
3. Link order is already correct: `$(CXX) $(CXXFLAGS) -o $@ $(OBJFILES) $(LDFLAGS)`.

```bash
docker run --rm -v /mnt/cache/appdata/cli-tools/bin:/out alpine:3.20 sh -c '
  apk add --no-cache build-base openssl-dev openssl-libs-static pkgconf git &&
  git clone --depth 1 -b 0.7.0 https://github.com/AGWA/git-crypt /src && cd /src &&
  make CXXFLAGS="-Wall -O2 -std=c++11 -DOPENSSL_API_COMPAT=0x10100000L" LDFLAGS="-static -lcrypto" &&
  strip git-crypt && cp git-crypt /out/'
```

`/mnt/cache/appdata/cli-tools/bin/git-crypt`, 4.7 MB, statically linked, runs under `env -i`.
`restore-cli-tools` links it to `/usr/local/bin/git-crypt` and smoke-tests it.

**The filter is pinned to the absolute stash path**, because `git-crypt init` writes a bare
`"git-crypt"` that depends on `PATH` *and* on `restore-cli-tools` having run — exactly the
silent-plaintext failure mode. Confirmed the bare form was written, then overridden:

```
filter.git-crypt.clean  = /mnt/cache/appdata/cli-tools/bin/git-crypt clean
filter.git-crypt.smudge = /mnt/cache/appdata/cli-tools/bin/git-crypt smudge
filter.git-crypt.required = true      # see §6
```

## 4. Phase 2 — The sweep

Filename sweep plus a three-tier content sweep over all 145,420 tracked files
(`scratchpad/sweep.sh`; emits **paths only**, never values). 186 content hits the filename sweep
would have missed. Findings a filename-based list structurally could not produce:

- **`compose/productivity-stack/docker-compose.yml`** — a credential hardcoded inline in a compose
  YAML. The handoff covered only `compose/**/.env`.
- **`sabnzbd.ini` + three stale `.bak`/`.new`/`.0` copies** — API keys in ordinary `.ini` files.
- **`compose/media-stack/.env.bak-preseerr`** — a `.env` backup that `compose/**/.env` misses.
- **`letsencrypt/accounts/**/private_key.json`** — the certbot **ACME account key in JWK format**.
  No `BEGIN PRIVATE KEY` header, no `.key`/`.pem` suffix, so *both* sweeps missed it. Found only
  by manually following up a symlink oddity. A dedicated JWK pass (`"kty"`/`"d"` + long base64)
  then confirmed it was the only one of its kind.

Two `.gitattributes` bugs caught during validation:

- Patterns containing a **space** must be double-quoted, else git parses the second word as an
  attribute name (`Trust Tokens*` → "not a valid attribute name").
- `git check-attr --stdin -z -- filter` is **wrong** — `--` separates attributes from *pathnames*,
  so git reports "No attribute specified" and matches nothing. Correct: `... -z filter`. This bug
  was also in the first draft of the guard, where it would have made the hook pass unconditionally.

## 5. Phases 3–4 — Slimming and the history purge

`purge-paths.txt` (annotated) drops **72,407 of 145,420 files (~1.9 GB)** of vendored code: a
python venv, the Android SDK, a JDK, `node_modules`, minified HACS JS, a Codex scratch clone, and
an abandoned Sourcegraph fork (`docker ps -a` confirms no such container exists).

**`appdata/android-build` is not excluded wholesale.** Of its 23,792 files only three subtrees are
bulk; the other four are `adbkey`, `adbkey.pub`, `debug.keystore`, `env.fish`. Losing
`debug.keystore` breaks Shield app upgrades with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; losing
`adbkey` forces a physical re-authorisation on the TV. `adbkey` and `debug.keystore` are now
**encrypted and kept**.

### ⚠️ 5a. The enumeration bug — the most important lesson here

The purge took **three passes** because the first two used a flawed path enumeration:

```bash
git rev-list --all --objects        # ← WRONG for this purpose
```

`rev-list --objects` **deduplicates by blob SHA and prints only one path per blob.** Any file whose
content is byte-identical to another file appears under just one of its names. That silently
omitted `appdata/netdata/**` (identical to `netdata-dump/**`) and `compose/photos-stack/.env`
(identical to another stack's `.env`) — 24,756 paths found versus **73,432 actually present**.

Worse, the post-purge check compared against that *same* incomplete list and therefore reported
"0 remaining" — **a verification that could not fail.** The real state was only exposed by scanning
every blob in the fetched clone. At that point real plaintext private keys had already been pushed.

Correct, exhaustive enumeration:

```bash
git rev-list --all | while read -r c; do git ls-tree -r --name-only "$c"; done | sort -u
```

**Rule: never verify a purge with the same enumeration that drove it.** The trustworthy check walks
every tree of every commit and inspects blob headers directly.

## 6. Phase 6 — The guard, two layers, both failure-tested

**Layer 1 — `filter.git-crypt.required = true`.** Added beyond the original plan. Git treats a
filter failure as fatal, so a missing binary makes `git add` itself fail and plaintext never
reaches the index. Tested by hiding the binary:

```
fatal: compose/guardtest-stack/.env: clean filter 'git-crypt' failed
```

**Layer 2 — `.git/hooks/pre-commit`.** Derives protected paths from `.gitattributes` via
`check-attr`, so it cannot drift out of sync, and deliberately **never invokes git-crypt** — the
binary being gone is the very thing it guards. Tested by setting `required=false` and staging
plaintext: the file *did* stage (proving the silent-leak scenario is real) and the hook aborted the
commit with HEAD unchanged.

**Symlinks are skipped by design.** Git never runs clean/smudge filters on symlinks, so
`letsencrypt/live/*.pem` (symlinks into `../../archive/`) can never be encrypted. Their blob is the
link target string, not certificate data. The hook now checks index mode `120000` and skips them —
without that it aborted every commit. Separately worth noting: `letsencrypt/archive/` is **not
backed up at all**, so those symlinks dangle in the repo — a coverage gap, tracked under I10.

## 7. Phase 7 — Verification

1. Committed blobs at protected paths start with `GITCRYPT`; working tree stays plaintext. ✅
2. **Fresh clone from GitHub**, exhaustive scan of every blob in every tree: the only plaintext at
   secret-shaped paths is two **symlinks** and two **`.env.example`** templates (every value
   commented out, `hf_xxxxx` placeholders). ✅
3. **Restore path:** clone → `git-crypt unlock <key>` → `core.config_entries` parses as JSON with
   **59 entries** (exactly the handoff's figure); `media-stack/.env` decrypts **byte-identical** to
   the live original; ACME `private_key.json` is a valid JWK. ✅
4. Failure simulation for both guard layers. ✅

## 8. Phase 9 — Plugin release (still to do)

Config-only fixes are **already live**; these are code changes needing a version bump + release:

1. `git-backup.cfg` / `.plg` defaults: `GITCRYPT_ENABLED`, `GITCRYPT_BIN`.
2. `validate_prereqs()` (`backup.sh:111`) — fail *before* gathering: binary executable, repo
   unlocked (`.git/git-crypt/keys/default`), `.gitattributes` present.
3. `git_commit_and_push()` — run the guard after `git add -A`, so the abort is logged by the
   plugin's own logger rather than only by git.
4. `init-repo.sh` — install the `pre-commit` hook, set `filter.git-crypt.required`, and add the new
   `.gitignore` excludes. It does `cat > .gitignore`, so a fresh install would otherwise lose them.
5. `git-backup.page` — surface git-crypt status beside the cron status.
6. `./build.sh`, bump `<!ENTITY version>`, `<CHANGES>`, tag, release, upload `.txz`, reinstall.

## 9. Live config changes (already applied)

`/boot/config/plugins/git-backup/git-backup.cfg` — backed up first to
`/mnt/user/backup/unraid-config-git-backup-PREENCRYPT-20260728/git-backup.cfg.bak-20260729`.

- **I1:** `HAOS_HOST` → `homeassistant.home.arpa`. `.local` *currently* resolves here, so this is a
  fragility fix, not a live breakage. **Non-obvious risk handled:** `backup_haos()` runs an SSH
  connectivity test with `BatchMode=yes` and *without* `accept-new` (unlike the rsync below it), so
  an unknown hostname would fail the whole HAOS backup. The host key for the new alias was verified
  byte-identical to the already-trusted entries for `10.100.10.140` and `homeassistant.local`
  before being added to `known_hosts`, then the exact non-interactive invocation was tested.
  (`/root/.ssh` symlinks to `/boot/config/ssh/root`, so this persists.)
- **I10:** added the helper/registry files that were genuinely missing — verified present in live
  `.storage`: `input_boolean`, `person`, `core.floor_registry`, `core.label_registry`,
  `core.config`, `homeassistant.exposed_entities`, `assist_pipeline.pipelines`, plus globs for
  helper types not yet created. **Deliberately excluded:** `auth`, `auth_provider.homeassistant`,
  `http.auth`, `cloud`, `application_credentials`, `androidtv_remote_*.pem`, alexa `*.pickle` —
  needed for a *full* restore but a wider secret surface, which is a separate call.
- Vendored-tree excludes so rsync stops copying back what was purged, and `.storage/tmp*` /
  `trace.saved_traces` / `core.restore_state` excluded as volatile churn.

### 9a. Two regressions I introduced and fixed the same night

Both were caught by *running the real backup* rather than trusting the config change.

1. **`.storage/core.config` is mode `0600 root:root`** on HAOS and the `justin` SSH user cannot
   read it, which failed the entire HAOS rsync with **exit 23** (it had succeeded the night
   before). Removed from `HAOS_INCLUDE`. Everything else added is readable;
   `core.category_registry` does not exist yet, and a missing include is harmless.

2. **⚠ `OVERRIDE_<CONTAINER>_EXCLUDE` REPLACES `GLOBAL_EXCLUDE`, it does not extend it.**
   See `resolve_container_rules()` (`backup.sh:151`) — tier 3 sets `CONTAINER_EXCLUDE` to the
   override alone. So adding a per-container override silently dropped `.git/**`,
   `node_modules/**`, `cache/**` etc. for `android-build`, `faster-whisper` and `cli-tools`.
   Consequences: 8,747 nvm/npm files pulled in, and a nested `.git` recorded as a **gitlink**,
   which made `git add -A` fail outright — *that would have failed the 03:00 cron.*
   The cfg is `source`d as bash, so each override now composes `"${GLOBAL_EXCLUDE},..."`.

   Side benefit: `.git` is now in `GLOBAL_EXCLUDE`, so nested repos are stored as ordinary files.
   `appdata/Profilarr/db` had been a gitlink since 2026-05-26 — i.e. only a commit SHA, its **795
   files were never actually backed up.** They are now.

This is worth fixing in the plugin itself: an override that silently discards the global safety
excludes is a footgun. Either merge the two tiers or warn when an override omits `.git/**`.

## 10. Outstanding

1. **Off-box copy of `/boot/config/plugins/git-backup/git-crypt.key`.** Not done. `/boot` is a
   single USB stick; key loss makes `core.config_entries` permanently unreadable and the HA restore
   path dead. This is the largest remaining risk.
2. **Rotation.** Deferred. The plaintext is purged from the current history, but **GitHub may
   retain unreachable objects** for a period after a force-push, and the old objects were briefly
   public-to-anyone-with-the-SHA (repo is private, so exposure is limited). Credentials that were
   pushed in plaintext at some point: netdata API keys + `cloud.d/private.pem`, kraken
   `claude-token.env`, `photos-stack/.env`, the ACME account key, and everything in the original
   handoff §2.1 list. **Z-Wave keys: do not rotate** — full exclude/re-include of every secure
   device including the Yale lock.
3. **Phase 0 archive** (`repo-full.tar.zst`, 2.3 GB) still holds plaintext secrets. Delete once
   confident, but not before — it is the only copy of the pre-rewrite history.
4. `letsencrypt/archive/` not backed up (dangling symlinks) — I10 follow-up.
5. Plugin release (§8).
