#!/bin/bash
# backup.sh — Main backup script for git-backup Unraid plugin
#
# Backs up:
#   1. Docker container config files from appdata
#   2. Docker compose files
#   3. HAOS (Home Assistant OS) config via SSH
#   4. Unraid system config files
#
# Then commits and pushes to git.
#
# Usage:
#   backup.sh [--dry-run] [--verbose]

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────
PLUGIN_DIR="/usr/local/emhttp/plugins/git-backup"
CONFIG="/boot/config/plugins/git-backup/git-backup.cfg"
KNOWLEDGE_FILE="$PLUGIN_DIR/data/container-knowledge.yml"
LOCKFILE="/var/run/git-backup.lock"

# ── State ─────────────────────────────────────────────────────────
CHANGES_DETECTED=0
HAOS_FAILED=0
ERRORS=0
VERBOSE="no"
CONTAINERS_BACKED_UP=0
FILES_SYNCED=0

# ── Logging ───────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [ -n "${LOG_FILE:-}" ] && echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

log_verbose() {
    [ "$VERBOSE" = "yes" ] && log "  $*"
}

# ── Lock Management (atomic via flock) ───────────────────────────
acquire_lock() {
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        log "ERROR: Another backup is running. Exiting."
        exit 1
    fi
    # Lock held until script exits (fd 200 closes automatically)
}

# Single cleanup function — handles ALL temp resources.
# Bash only supports one trap per signal, so we consolidate here.
cleanup() {
    rm -f "$LOCKFILE" "${KB_CACHE:-}"
}

# ── Config Loading ───────────────────────────────────────────────
load_config() {
    if [ ! -f "$CONFIG" ]; then
        log "ERROR: Config not found: $CONFIG"
        exit 1
    fi
    # INI KEY="value" is valid bash assignment
    source "$CONFIG"

    # Source the YAML parser
    source "$PLUGIN_DIR/scripts/parse-yaml.sh"

    # Pre-parse knowledge base into cache (avoids re-parsing per container)
    KB_CACHE=$(mktemp /tmp/git-backup-kb.XXXXXX)
    parse_yaml_containers "$KNOWLEDGE_FILE" > "$KB_CACHE" 2>/dev/null || true
}

# ── Argument Parsing ─────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   DRY_RUN="yes" ;;
            --verbose)   VERBOSE="yes" ;;
            --help|-h)
                echo "Usage: backup.sh [--dry-run] [--verbose]"
                echo "  --dry-run   Preview what would be backed up (no git operations)"
                echo "  --verbose   Show detailed file-level output"
                exit 0
                ;;
            *)
                log "Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done
}

# ── Prerequisites ────────────────────────────────────────────────
validate_prereqs() {
    # Check git repo exists
    if [ ! -d "$REPO_PATH/.git" ]; then
        log "ERROR: Git repo not initialized at $REPO_PATH"
        log "Run: $PLUGIN_DIR/scripts/init-repo.sh"
        exit 1
    fi

    # Check appdata path exists
    if [ ! -d "$APPDATA_PATH" ]; then
        log "ERROR: Appdata path not found: $APPDATA_PATH"
        exit 1
    fi

    # Rotate log if too large
    if [ -f "$LOG_FILE" ]; then
        local log_size_kb
        log_size_kb=$(( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) / 1024 ))
        if [ "$log_size_kb" -gt "${LOG_MAX_SIZE_KB:-1024}" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "Log rotated (was ${log_size_kb}KB)"
        fi
    fi
}

# ── Folder Name → Override Key ───────────────────────────────────
folder_to_key() {
    # Convert folder name to INI override key format
    # "Plex-Media-Server" → "PLEX_MEDIA_SERVER"
    # Pure bash — no subshells, no forks
    local val="${1^^}"           # uppercase (bash 4+)
    val="${val//[-. ]/_}"        # replace -, ., space with _
    echo "${val//[^A-Z0-9_]/}"  # strip non-alphanumeric/underscore
}

# ── Three-Tier Rule Resolution ───────────────────────────────────
# Sets: CONTAINER_MODE ("include" or "exclude")
#       CONTAINER_INCLUDE (comma-separated)
#       CONTAINER_EXCLUDE (comma-separated)
resolve_container_rules() {
    local folder="$1"
    local folder_key
    folder_key=$(folder_to_key "$folder")

    # --- Tier 3: Per-container overrides (highest priority) ---
    local override_include_var="OVERRIDE_${folder_key}_INCLUDE"
    local override_exclude_var="OVERRIDE_${folder_key}_EXCLUDE"

    if [ -n "${!override_include_var:-}" ] || [ -n "${!override_exclude_var:-}" ]; then
        log_verbose "Rules: user override for $folder"
        if [ -n "${!override_include_var:-}" ]; then
            CONTAINER_MODE="include"
            CONTAINER_INCLUDE="${!override_include_var}"
            CONTAINER_EXCLUDE=""
        else
            CONTAINER_MODE="exclude"
            CONTAINER_INCLUDE=""
            CONTAINER_EXCLUDE="${!override_exclude_var}"
        fi
        return 0
    fi

    # --- Tier 2: Knowledge base match (by folder name) ---
    if [ -f "$KB_CACHE" ] && [ -s "$KB_CACHE" ]; then
        while IFS='|' read -r kb_name kb_folder kb_include kb_exclude; do
            # Case-insensitive folder match
            if [ -n "$kb_folder" ] && [ "${folder,,}" = "${kb_folder,,}" ]; then
                log_verbose "Rules: knowledge base match '$kb_name'"
                if [ -n "$kb_include" ]; then
                    CONTAINER_MODE="include"
                    CONTAINER_INCLUDE="$kb_include"
                    CONTAINER_EXCLUDE=""
                else
                    CONTAINER_MODE="exclude"
                    CONTAINER_INCLUDE=""
                    CONTAINER_EXCLUDE="$kb_exclude"
                fi
                return 0
            fi
        done < "$KB_CACHE"
    fi

    # --- Tier 1: Global defaults (lowest priority) ---
    log_verbose "Rules: global defaults"
    CONTAINER_MODE="exclude"
    CONTAINER_INCLUDE=""
    CONTAINER_EXCLUDE="$GLOBAL_EXCLUDE"
    return 0
}

# ── Build rsync Include Args ─────────────────────────────────────
# For include mode, we need to explicitly include parent directories
# so rsync can traverse into nested paths.
#
# Uses nameref (bash 4.3+) to append directly to caller's array,
# avoiding word-splitting bugs with paths containing spaces
# (e.g., "Library/Application Support/Plex Media Server/Preferences.xml").
build_include_args() {
    local pattern="$1"
    local -n _out_args=$2   # nameref: writes directly to caller's array

    # Decompose "a/b/c/file.xml" into:
    #   --include="a/"
    #   --include="a/b/"
    #   --include="a/b/c/"
    #   --include="a/b/c/file.xml"
    local path_so_far=""
    IFS='/' read -ra segments <<< "$pattern"

    # All but the last segment are directories
    local num_segments=${#segments[@]}
    for (( i=0; i<num_segments-1; i++ )); do
        path_so_far="${path_so_far}${segments[$i]}/"
        _out_args+=(--include="$path_so_far")
    done

    # The last segment is the actual file/glob
    if [ "$num_segments" -gt 1 ]; then
        _out_args+=(--include="${path_so_far}${segments[$((num_segments-1))]}")
    else
        _out_args+=(--include="$pattern")
    fi
}

# ── Backup Single Container ──────────────────────────────────────
backup_single_container() {
    local folder="$1"
    local src="$APPDATA_PATH/$folder/"
    local dest="$REPO_PATH/appdata/$folder/"

    # Skip check
    if [ -n "$SKIP_CONTAINERS" ]; then
        IFS=',' read -ra skip_list <<< "$SKIP_CONTAINERS"
        for skip in "${skip_list[@]}"; do
            [ "$(echo "$skip" | tr -d ' ')" = "$folder" ] && {
                log_verbose "Skipped: $folder (in skip list)"
                return 0
            }
        done
    fi

    # Source must exist
    [ -d "$src" ] || return 0

    resolve_container_rules "$folder"

    mkdir -p "$dest"

    # Build rsync command
    local rsync_args=(-a --delete --max-size="${MAX_FILE_SIZE_KB}K")

    if [ "$CONTAINER_MODE" = "include" ]; then
        # Allowlist mode: include specific patterns, exclude everything else
        IFS=',' read -ra includes <<< "$CONTAINER_INCLUDE"
        for inc in "${includes[@]}"; do
            build_include_args "$inc" rsync_args
        done
        rsync_args+=(--include="*/")  # allow directory traversal for glob patterns
        rsync_args+=(--exclude="*")
        rsync_args+=(--prune-empty-dirs)
    else
        # Denylist mode: exclude specified patterns
        IFS=',' read -ra excludes <<< "$CONTAINER_EXCLUDE"
        for exc in "${excludes[@]}"; do
            rsync_args+=(--exclude="$exc")
        done
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        rsync_args+=(--dry-run -v)
    elif [ "$VERBOSE" = "yes" ]; then
        rsync_args+=(-v)
    fi

    local output
    output=$(rsync "${rsync_args[@]}" "$src" "$dest" 2>&1) || true

    if [ "$VERBOSE" = "yes" ] || [ "$DRY_RUN" = "yes" ]; then
        # Show first 20 lines of output if non-empty
        # Use <<< to avoid broken pipe from echo|head with pipefail
        if [ -n "$output" ]; then
            head -20 <<< "$output" || true
        fi
    fi

    CONTAINERS_BACKED_UP=$((CONTAINERS_BACKED_UP + 1))
}

# ── Backup Appdata ───────────────────────────────────────────────
backup_appdata() {
    log "Backing up appdata containers..."
    local count=0

    for dir in "$APPDATA_PATH"/*/; do
        [ -d "$dir" ] || continue
        local folder
        folder=$(basename "$dir")
        log_verbose "Processing: $folder"
        backup_single_container "$folder"
        count=$((count + 1))
    done

    log "  Processed $count containers"

    # Clean up orphaned directories (containers that no longer exist)
    for repo_dir in "$REPO_PATH/appdata"/*/; do
        [ -d "$repo_dir" ] || continue
        local orphan
        orphan=$(basename "$repo_dir")
        if [ ! -d "$APPDATA_PATH/$orphan" ]; then
            log "  Removing orphaned: appdata/$orphan"
            if [ "$DRY_RUN" = "yes" ]; then
                log_verbose "  Would remove: $repo_dir"
            else
                rm -rf "$repo_dir"
            fi
        fi
    done
}

# ── Backup Compose Files ─────────────────────────────────────────
backup_compose() {
    [ "$COMPOSE_ENABLED" = "yes" ] || return 0
    [ -d "$COMPOSE_PATH" ] || {
        log "WARNING: Compose path not found: $COMPOSE_PATH"
        return 0
    }

    log "Backing up compose files..."
    local dest="$REPO_PATH/compose/"
    mkdir -p "$dest"

    local rsync_args=(-a --delete)
    [ "$DRY_RUN" = "yes" ] && rsync_args+=(--dry-run -v)
    [ "$VERBOSE" = "yes" ] && rsync_args+=(-v)

    rsync "${rsync_args[@]}" "$COMPOSE_PATH/" "$dest" 2>&1 || {
        log "WARNING: Compose backup had errors"
        ERRORS=$((ERRORS + 1))
    }

    log "  Done"
}

# ── Backup HAOS ──────────────────────────────────────────────────
backup_haos() {
    [ "$HAOS_ENABLED" = "yes" ] || return 0

    log "Backing up HAOS config..."
    local dest="$REPO_PATH/haos/"
    mkdir -p "$dest"

    # Test SSH connectivity first
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes \
         -p "$HAOS_PORT" -i "$HAOS_SSH_KEY" \
         "$HAOS_USER@$HAOS_HOST" "echo ok" &>/dev/null; then
        log "ERROR: Cannot SSH to HAOS at $HAOS_USER@$HAOS_HOST:$HAOS_PORT"
        log "  Check: SSH key ($HAOS_SSH_KEY), host ($HAOS_HOST), port ($HAOS_PORT)"
        HAOS_FAILED=1
        ERRORS=$((ERRORS + 1))
        return 0  # Continue with other backups
    fi

    # Build rsync args
    local rsync_args=(-az --delete
        -e "ssh -p $HAOS_PORT -i $HAOS_SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    )

    # Add excludes
    IFS=',' read -ra haos_excludes <<< "$HAOS_EXCLUDE"
    for exc in "${haos_excludes[@]}"; do
        # Strip leading /config/ to make relative
        local rel="${exc#/config/}"
        rsync_args+=(--exclude="$rel")
    done

    # Add includes (with parent directory decomposition)
    IFS=',' read -ra haos_includes <<< "$HAOS_INCLUDE"
    for inc in "${haos_includes[@]}"; do
        local rel="${inc#/config/}"
        build_include_args "$rel" rsync_args
    done
    rsync_args+=(--include="*/")
    rsync_args+=(--exclude="*")
    rsync_args+=(--prune-empty-dirs)

    [ "$DRY_RUN" = "yes" ] && rsync_args+=(--dry-run -v)
    [ "$VERBOSE" = "yes" ] && rsync_args+=(-v)

    if rsync "${rsync_args[@]}" "$HAOS_USER@$HAOS_HOST:/config/" "$dest" 2>&1; then
        log "  Done"
    else
        log "WARNING: HAOS backup had errors (rsync exit code $?)"
        HAOS_FAILED=1
        ERRORS=$((ERRORS + 1))
    fi
}

# ── Backup Unraid System Config ──────────────────────────────────
backup_unraid() {
    [ "$UNRAID_ENABLED" = "yes" ] || return 0

    log "Backing up Unraid system config..."
    local dest="$REPO_PATH/unraid/"
    mkdir -p "$dest"

    IFS=',' read -ra paths <<< "$UNRAID_PATHS"
    for path in "${paths[@]}"; do
        path=$(echo "$path" | tr -d ' ')  # trim whitespace

        if [ -f "$path" ]; then
            # Single file: preserve relative path from /boot/config/
            local rel="${path#/boot/config/}"
            local dir
            dir=$(dirname "$rel")
            mkdir -p "$dest/$dir"

            if [ "$DRY_RUN" = "yes" ]; then
                log_verbose "Would copy: $path -> $dest/$rel"
            else
                cp -p "$path" "$dest/$rel" 2>/dev/null || {
                    log "WARNING: Could not copy $path"
                    ERRORS=$((ERRORS + 1))
                }
            fi
        elif [ -d "$path" ]; then
            # Directory: rsync
            local rel="${path#/boot/config/}"
            mkdir -p "$dest/$rel"

            local rsync_args=(-a --delete)
            [ "$DRY_RUN" = "yes" ] && rsync_args+=(--dry-run -v)

            rsync "${rsync_args[@]}" "$path/" "$dest/$rel/" 2>&1 || {
                log "WARNING: Error syncing $path"
                ERRORS=$((ERRORS + 1))
            }
        else
            log_verbose "Skipped (not found): $path"
        fi
    done

    log "  Done"
}

# ── Git Commit & Push ────────────────────────────────────────────
git_commit_and_push() {
    cd "$REPO_PATH" || { log "ERROR: Cannot cd to $REPO_PATH"; return 1; }

    # Stage all changes
    git add -A

    # Check for changes
    if git diff --cached --quiet; then
        log "No changes detected. Nothing to commit."
        CHANGES_DETECTED=0
        return 0
    fi

    CHANGES_DETECTED=1

    # Build commit message
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local changed_files
    changed_files=$(git diff --cached --numstat | wc -l)
    local summary
    summary=$(git diff --cached --stat | tail -1)
    local msg="${COMMIT_PREFIX} ${timestamp} (${changed_files} files) ${summary}"

    git commit -m "$msg" 2>&1 || {
        log "ERROR: Git commit failed"
        ERRORS=$((ERRORS + 1))
        return 1
    }
    log "Committed: $msg"

    # Push if configured
    if [ "$PUSH_AFTER_COMMIT" = "yes" ] && [ -n "$REMOTE_URL" ]; then
        log "Pushing to $REMOTE_NAME/$BRANCH..."
        if git push "$REMOTE_NAME" "$BRANCH" 2>&1; then
            log "  Push successful"
        else
            log "ERROR: Git push failed"
            ERRORS=$((ERRORS + 1))
            return 1
        fi
    fi

    return 0
}

# ── Notifications ────────────────────────────────────────────────
send_notification() {
    [ "$NOTIFICATION" = "yes" ] || return 0

    local notify_script="/usr/local/emhttp/webGui/scripts/notify"
    [ -x "$notify_script" ] || return 0  # Skip if not on Unraid

    local exit_code=${1:-0}

    if [ "$exit_code" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
        if [ "$CHANGES_DETECTED" -eq 1 ]; then
            "$notify_script" \
                -s "Git Backup" \
                -d "Backup completed successfully ($CONTAINERS_BACKED_UP containers)" \
                -i "normal" \
                -e "git-backup" 2>/dev/null || true
        fi
        # No notification for "no changes" to reduce noise
    else
        local detail=""
        [ "$HAOS_FAILED" -eq 1 ] && detail="HAOS sync failed. "
        [ "$ERRORS" -gt 0 ] && detail="${detail}${ERRORS} error(s). "

        "$notify_script" \
            -s "Git Backup" \
            -d "Backup completed with issues. ${detail}Check: $LOG_FILE" \
            -i "warning" \
            -e "git-backup" 2>/dev/null || true
    fi
}

# ── Dry Run Summary ─────────────────────────────────────────────
show_dry_run_summary() {
    echo ""
    echo "════════════════════════════════════════════"
    echo "  DRY RUN COMPLETE — No changes were made"
    echo "════════════════════════════════════════════"
    echo ""
    echo "Containers scanned: $CONTAINERS_BACKED_UP"
    echo "Repo path: $REPO_PATH"
    [ "$HAOS_ENABLED" = "yes" ] && echo "HAOS: enabled (host: $HAOS_HOST)"
    [ "$HAOS_FAILED" -eq 1 ] && echo "HAOS: FAILED to connect"
    echo ""
    echo "Remove --dry-run to perform the actual backup."
}

# ── Main ─────────────────────────────────────────────────────────
main() {
    load_config
    parse_args "$@"
    acquire_lock
    trap cleanup EXIT   # single trap: cleans up lockfile + KB cache
    validate_prereqs

    log "═══ Git Backup started ═══"
    [ "$DRY_RUN" = "yes" ] && log "  (DRY RUN — no git operations)"

    backup_appdata
    backup_compose
    backup_haos
    backup_unraid

    if [ "$DRY_RUN" = "yes" ]; then
        show_dry_run_summary
    else
        # Use || to prevent set -e from aborting before notification
        local git_rc=0
        git_commit_and_push || git_rc=$?
        send_notification "$git_rc"
    fi

    if [ "$ERRORS" -gt 0 ]; then
        log "═══ Git Backup completed with $ERRORS error(s) ═══"
    else
        log "═══ Git Backup completed successfully ═══"
    fi
}

main "$@"
