#!/bin/bash
# git-backup secrets guard.
#
# Aborts the commit if any path that .gitattributes marks filter=git-crypt is
# staged as PLAINTEXT. Without this, a missing/broken git-crypt binary makes
# git's clean filter silently no-op: the nightly backup would commit real
# credentials and push them to GitHub, looking like a successful run.
#
# Deliberately does NOT invoke git-crypt — the binary being gone is exactly the
# failure this guards against, so the check must work without it.
#
# Installed by the git-backup plugin's init-repo.sh into .git/hooks/pre-commit.

set -uo pipefail

fail=0
checked=0

# Symlinks (index mode 120000) can never be encrypted: git does not run
# clean/smudge filters on them. Their blob is the link target string, not file
# content, so there is no secret to protect. Certbot's letsencrypt/live/*.pem
# are exactly this — symlinks into ../../archive/, where the real (encrypted)
# certificate lives. Collect them once and skip them below.
declare -A IS_SYMLINK=()
while read -r mode _rest; do
    [ "$mode" = "120000" ] || continue
    path="${_rest#*$'\t'}"
    IS_SYMLINK["$path"]=1
done < <(git ls-files -s --cached)

# NOTE: `git check-attr --stdin -z filter` — do NOT write `-- filter`.
# `--` separates attributes from PATHNAMES, so `-- filter` makes git report
# "No attribute specified", the loop body never runs, and this hook would
# silently pass everything. A guard that never fires is worse than no guard.
while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
    [ "$value" = "git-crypt" ] || continue
    [ -n "${IS_SYMLINK[$path]:-}" ] && continue
    checked=$((checked + 1))

    # Raw STAGED blob — no smudge filter is applied, so this is exactly what
    # would be committed. Checking the working tree would prove nothing, since
    # git-crypt leaves the working tree in plaintext by design.
    header=$(git cat-file -p ":$path" 2>/dev/null | head -c 10 | tr -d '\0')

    if [ "${header:0:8}" != "GITCRYPT" ]; then
        echo "ABORT: $path is staged as PLAINTEXT (git-crypt filter did not run)" >&2
        fail=1
    fi
done < <(git ls-files -z --cached | git check-attr --stdin -z filter)

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'
ABORT: refusing to commit — protected files would be stored unencrypted.

Check, in order:
  1. git-crypt present?   "$GITCRYPT_BIN" --version   (see git-backup.cfg)
  2. repo unlocked?       test -f .git/git-crypt/keys/default
  3. filter configured?   git config --get filter.git-crypt.clean
                          (should be an ABSOLUTE path — a bare name depends on
                           PATH, and on Unraid /usr is rebuilt from RAM at boot)
  4. re-stage after fixing: git-crypt status -f

A missed backup is recoverable. A pushed credential is not.
EOF
    exit 1
fi

# A count of zero means .gitattributes is missing or matched nothing — which is
# itself the silent-plaintext condition this hook exists to prevent.
if [ "$checked" -eq 0 ]; then
    echo "ABORT: no git-crypt-protected paths matched. Is .gitattributes present?" >&2
    exit 1
fi

exit 0
