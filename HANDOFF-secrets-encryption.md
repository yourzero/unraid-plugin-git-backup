# Handoff – Encrypting secrets in the Unraid config-backup repo

**Prepared:** 28 July 2026, by a Claude Code session on `mc-nas`
**Audience:** the next LLM session, which will implement this and update the `git-backup` plugin
**Scope:** secrets handling in the backup repo only. Not the backup's coverage, not Home
Assistant config, not the plugin's other behaviour.
**Status:** nothing has been changed. Everything below is verified read-only observation.

---

## 0. Summary

The Unraid `git-backup` plugin commits config nightly to a local git repo and **pushes it to
GitHub**. That repo currently contains **plaintext credentials** – Z-Wave network keys, service
API keys, VPN credentials, and Claude Code's own OAuth token. The repo is **private**, so this is
not an open leak, but it concentrates high-value secrets in a third-party service and git history
makes them permanent.

**Decision already made by Justin: use git-crypt.** Your job is to implement it and update the
plugin so the nightly job keeps working.

**The single most important thing in this document is §6** – if git-crypt is not active when the
cron job runs, the backup will silently commit plaintext and push it. Build the guard.

---

## 1. Verified current state

| Fact | Value | How verified |
|---|---|---|
| Repo path | `/mnt/cache/unraid-config-git-backup` | – |
| Remote | `git@github.com:yourzero/unraid-configs.git` | `git remote -v` |
| Visibility | **Private** | unauthenticated `api.github.com/repos/...` → **404** |
| Branch / commits | `main`, **27 commits**, tracking `origin/main` | `git branch -vv` |
| Pushed? | **Yes** – today's 03:06 commit is on `origin/main` | `git log origin/main` |
| Tracked files | **145,420** | `git ls-files \| wc -l` |
| `.git` size | **1.6 GB** | `du -sh` |
| Existing `.gitattributes` | **none** | – |
| Plugin config | `/boot/config/plugins/git-backup/git-backup.cfg` (persistent) | – |
| Plugin code | `/usr/local/emhttp/plugins/git-backup/` – **RAM-backed, rebuilt at boot from the `.plg`** | – |
| Trigger | `/etc/cron.d/git-backup` → `0 3 * * * /usr/local/emhttp/plugins/git-backup/scripts/backup.sh` | – |
| `git` version | 2.51.1 | – |
| `git-crypt` / `gpg` / `age` / `sops` | **none installed** | `command -v` |

**Correction to `/root/.claude/CLAUDE.md`:** it claims the plugin source is cloned at
`/mnt/cache/scripts/unraid-plugin-git-backup`. **That path does not exist.** Re-locate the source
before attempting a plugin change, and fix that line in CLAUDE.md when you do.

---

## 2. What needs encrypting

### 2.1 Confirmed present in the repo

**Home Assistant (the original trigger):**
- `haos/secrets.yaml`
- `haos/.storage/core.config_entries` – 59 entries, 21 carrying credentials. Fields observed:
  `api_key`, `client_secret`, `password`, `cync_credentials`, and the **Z-Wave network keys**
  `s0_legacy_key`, `s2_authenticated_key`, `s2_access_control_key`, `lr_s2_access_control_key`,
  `lr_s2_authenticated_key`. Those protect the S2-paired Yale door lock (`lock.node_3`).

**Everything else – the scope grew when checked:**
- All **7 compose `.env` files**: `compose/{media-stack,ai,Immich,backup-stack,photos-stack,...}/.env`.
  Per CLAUDE.md, `media-stack/.env` holds live VPN credentials and a Plex claim token.
- `appdata/cli-tools/home/.claude/.credentials.json` – **Claude Code's own OAuth credentials**
- `appdata/cli-tools/home/.claude/daemon/control.key`
- `appdata/kraken-trader/secrets/claude-token.env`
- `appdata/NginxProxyManager/letsencrypt/credentials/credentials-3` – DNS-API credentials used
  for certificate issuance
- `appdata/binhex-sabnzbd/config/admin/server.key` and `config.0/admin/server.key`
- `appdata/netdata/lib/netdata.api.key`, `appdata/netdata-dump/lib/netdata.api.key`
- `appdata/obsidian/ssl/cert.key`
- `appdata/sillytavern/data/default-user/secrets.json`
- `appdata/sourcegraph/.../sourcegraph.key` plus Caddy PKI `root.key` / `intermediate.key` and an
  ACME account key under `.../users/jmac@mcki.nl/jmac.key`

### 2.2 Do this discovery step yourself

The list above came from one filename-pattern sweep and **is not exhaustive** – it finds files
named like secrets, not files containing them. Before finalising `.gitattributes`, sweep for
content too (high-entropy strings, `BEGIN .* PRIVATE KEY`, `password:`, `api[_-]?key`), and
review anything under `appdata/*/config/` for tokens embedded in ordinary config files.

### 2.3 Do NOT solve this by excluding files

An earlier draft suggested simply dropping `core.config_entries` from the backup. **That is
wrong** and the analysis is worth preserving:

- Only 21 of 59 entries hold credentials; the other 38 are pure config.
- `entry_id` in this file is what ties the other registries together: **1678 of 1747 entities and
  all 119 devices reference a config entry.** Without it, `core.entity_registry` and
  `core.device_registry` restore as orphaned pointers – a restore that *looks* valid and isn't.
- It holds tuning that exists nowhere else. Example: all three Adaptive Lighting instances
  (`Office Circadian`, `Bedroom Lights`, `Theater Lights`) keep their entire configuration in
  `options`, with no secrets involved.

Encrypt, don't exclude. The same logic applies to the compose `.env` files – they *are* the
service configuration, not just the secrets.

---

## 3. Approach: git-crypt in symmetric-key mode

Use **`git-crypt` with a symmetric key file**, not GPG mode.

Rationale: no GPG on this box, and GPG mode buys nothing for a single-operator setup. Symmetric
mode needs only the `git-crypt` binary plus a key file. `git-crypt init` and `git-crypt unlock`
work without GPG; only `git-crypt add-gpg-user` requires it.

git-crypt works via git's clean/smudge filters, so the nightly script keeps writing plaintext
into the working tree exactly as it does today, and git encrypts on commit. **No change to how
the backup gathers files** – which is why this is the low-friction option.

---

## 4. Environment constraints – read before implementing

1. **`/`, `/root` and `/usr` are rebuilt from RAM on every boot.** Install the `git-crypt` binary
   into the persistent stash at `/mnt/cache/appdata/cli-tools/` and symlink it into place via the
   existing `restore-cli-tools` User Script, the same pattern used for `claude` and `rtk`. A
   plain `installpkg`/`make install` will vanish on reboot – and that failure mode is exactly
   what §6 guards against.
2. **The plugin runs a pinned release build, not live source.** Per CLAUDE.md, changing plugin
   behaviour needs a version bump and release rather than a source edit – but the source clone
   path in CLAUDE.md is stale (§1), so confirm where the source actually lives first. If the
   change can be made entirely in `git-backup.cfg` and repo-side config (`.gitattributes`, hooks),
   **prefer that** and avoid touching the plugin at all.
3. **Cron fires at 03:00 daily** and runs as root. Whatever you do must work non-interactively
   with no TTY and no agent.
4. **The repo is 1.6 GB across 145k files**, including Android SDKs, a `faster-whisper` venv, and
   nested Sourcegraph backups. Any history rewrite will be slow. See §7.

---

## 5. Implementation outline

1. Obtain a static `git-crypt` binary (build or fetch), place it in
   `/mnt/cache/appdata/cli-tools/`, symlink into `PATH`, and add it to `restore-cli-tools` so it
   survives reboot. Verify with `git-crypt --version` **as root**, since cron runs as root.
2. In `/mnt/cache/unraid-config-git-backup`: `git-crypt init`.
3. Export the key: `git-crypt export-key /boot/config/plugins/git-backup/git-crypt.key`.
   See §8 – this file must never enter the repo.
4. Write `.gitattributes` at repo root from the §2 inventory. Pattern form:
   ```
   haos/secrets.yaml                     filter=git-crypt diff=git-crypt
   haos/.storage/core.config_entries     filter=git-crypt diff=git-crypt
   compose/**/.env                       filter=git-crypt diff=git-crypt
   appdata/cli-tools/home/.claude/.credentials.json filter=git-crypt diff=git-crypt
   ```
   **`.gitattributes` itself must not be encrypted.** Add an explicit
   `.gitattributes !filter !diff` line to be safe.
5. Commit `.gitattributes`, then re-commit the protected files so they are stored encrypted.
6. Implement the §6 guard.
7. Decide and execute the §7 history question.
8. Run the verification in §9 before considering it done.

---

## 6. ⚠️ The guard – the most important part

**Failure mode:** if the `git-crypt` binary is missing or the repo is not unlocked when
`backup.sh` runs, git's filter silently does not apply, the script commits **plaintext**, and
pushes it to GitHub. This is a silent leak that looks like a successful backup. It is a realistic
scenario on this box, because `/usr` is rebuilt from RAM every boot and the binary depends on a
restore script having already run.

**Required: fail loudly rather than leak.** Add a pre-commit check – as a repo hook, or in
`backup.sh` before it commits – that for every path matched by `.gitattributes` verifies the
staged blob begins with git-crypt's magic header:

```bash
# staged blob should start with \0GITCRYPT
git show ":$path" | head -c 9 | grep -q $'\0GITCRYPT' || { echo "ABORT: $path staged as plaintext"; exit 1; }
```

Abort the whole backup run on failure and make sure the failure is visible in
`/var/log/git-backup.log`. A missed backup is recoverable; a pushed credential is not.

Also verify `git-crypt` is present and the repo is unlocked at the *start* of the run, so it
fails early rather than after gathering 145k files.

---

## 7. The pre-existing history problem – needs a decision

**git-crypt only protects future commits.** All 27 existing commits contain the plaintext
secrets, they are already pushed to GitHub, and encrypting going forward does nothing about them.

Options:

- **(a) Accept it.** Private repo, single owner. Encrypt forward, rotate the cheap credentials
  (§7.1), move on. Lowest effort; the exposure persists in history.
- **(b) Purge the paths from history** with `git filter-repo`, then force-push. Cleanest result
  that keeps history. Slow on a 1.6 GB repo, and rewrites every commit – fine here since there is
  one owner and no other clones, but confirm that.
- **(c) Delete and recreate the GitHub repo** from a fresh initial commit. Simplest and fastest,
  loses the 27 commits of history – which are auto-generated `backup: <timestamp>` snapshots of
  limited forensic value. **Bonus:** a fresh start plus a better `.gitignore` would shed the
  Android SDK, the `faster-whisper` venv, and nested Sourcegraph backups currently bloating the
  repo to 1.6 GB. Fewer files also means less secret surface.

**Recommendation: (c)**, unless Justin values the commit history. Raise it with him.

### 7.1 On rotating credentials

Do **not** reflexively rotate everything.

- **Cheap and worth doing:** Claude Code credentials (just re-login), netdata API keys,
  SABnzbd server key, service API keys, the NPM DNS credential.
- **Expensive – do not touch without explicit instruction:** the **Z-Wave network keys**. Per the
  HA handoff brief §9.2, regenerating them forces a full exclude/re-include of *every* secure
  Z-Wave device, including the Yale lock. Given the repo is private, that cost is almost
  certainly not justified. Flag it to Justin, don't act.

---

## 8. Key management – the way this bites you

The git-crypt key is now the single thing standing between a rebuilt server and an unrecoverable
backup. **If it is lost, every encrypted file in the repo is permanently unreadable**, including
the `core.config_entries` needed to restore Home Assistant.

- Store it at `/boot/config/plugins/git-backup/git-crypt.key` – `/boot` is the USB flash and is
  one of only two persistent locations on this box.
- **Also store a copy off-box** – password manager or another machine. A key that exists only on
  the server it protects does not survive the disaster it exists for.
- Add it to `.gitignore` **and** verify it is not tracked: `git check-ignore -v <path>` plus
  `git ls-files | grep git-crypt.key` returning nothing.
- Note `/boot/config/plugins/git-backup/ssh/` already holds the HA backup SSH key, so this
  directory is already a secret store and should be treated as one.

---

## 9. Verification – do all of these

1. `git-crypt status` – protected files show as encrypted, nothing unexpected does.
2. **Inspect the stored blob, not the working tree:**
   `git cat-file -p HEAD:haos/secrets.yaml | head -c 9` → must show `GITCRYPT`, not YAML.
   The working tree stays plaintext by design, so a working-tree check proves nothing.
3. Confirm the same for at least one `.env` and for `core.config_entries`.
4. **Fetch from GitHub into a scratch clone** and confirm the file is encrypted there. This is the
   only check that verifies what actually left the box.
5. Simulate the §6 failure: temporarily rename the `git-crypt` binary, run the backup, and confirm
   it **aborts** rather than committing plaintext. Restore the binary afterwards.
6. Confirm a full restore path still works: clone, `git-crypt unlock <key>`, verify
   `core.config_entries` parses as JSON with 59 entries.
7. Let the real 03:00 cron run once, then check `/var/log/git-backup.log` and re-run check 4.

---

## 10. Rollback

`git-crypt` is additive – removing `.gitattributes` and re-committing restores plaintext. The risk
is not rollback, it is **key loss** (§8). Before starting, note that the current repo state is
recoverable from GitHub, and take a copy of `/boot/config/plugins/git-backup/` first.

---

## 11. Decisions needed from Justin

1. **History (§7):** accept, `filter-repo` purge, or delete-and-recreate the GitHub repo?
2. **Rotation (§7.1):** confirm the cheap rotations; confirm the Z-Wave keys are being left alone.
3. **Scope:** encrypt only the confirmed list in §2.1, or run the broader content sweep in §2.2
   first?
4. **Bonus, only if doing 7(c):** tighten `.gitignore` to drop the Android SDK, venvs, and nested
   Sourcegraph backups? Reduces 1.6 GB substantially and shrinks the secret surface.

---

## 12. Explicitly out of scope

- Backup *coverage* – whether the right files are being backed up. Tracked separately as **I10**
  in `TODOs.md`.
- Home Assistant config, automations, and entity issues – tracked as the **H** items.
- The `HAOS_HOST="homeassistant.local"` mDNS fragility – tracked as **I1**. Unrelated to secrets,
  but the next session will be editing the same `git-backup.cfg`, so it is a free fix while in
  there.
