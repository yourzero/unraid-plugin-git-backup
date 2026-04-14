#!/bin/bash
# ssh-keygen.sh — Generate and manage SSH keys for git-backup plugin
#
# Keys are stored on the USB flash drive (persistent across reboots)
# and copied to /root/.ssh/ at runtime.
#
# Usage:
#   ssh-keygen.sh git      # Generate key for git remote
#   ssh-keygen.sh haos     # Generate key for HAOS
#   ssh-keygen.sh install   # Copy keys from USB to /root/.ssh/ (called on boot)
#   ssh-keygen.sh show git  # Show public key for git
#   ssh-keygen.sh show haos # Show public key for HAOS

set -euo pipefail

PLUGIN="git-backup"
SSH_PERSIST_DIR="/boot/config/plugins/$PLUGIN/ssh"
SSH_RUNTIME_DIR="/root/.ssh"

# Key paths (persistent on USB flash)
GIT_KEY="$SSH_PERSIST_DIR/git_backup_key"
HAOS_KEY="$SSH_PERSIST_DIR/haos_backup_key"

# Ensure directories exist
mkdir -p "$SSH_PERSIST_DIR"
mkdir -p "$SSH_RUNTIME_DIR"
chmod 700 "$SSH_PERSIST_DIR"
chmod 700 "$SSH_RUNTIME_DIR"

generate_key() {
    local purpose="$1"
    local key_path="$2"
    local comment="git-backup-${purpose}@$(hostname)"

    if [ -f "$key_path" ]; then
        echo "Key already exists: $key_path"
        echo ""
        echo "Public key:"
        echo "────────────────────────────────────────"
        cat "${key_path}.pub"
        echo "────────────────────────────────────────"
        echo ""
        echo "To regenerate, delete the existing key first:"
        echo "  rm $key_path ${key_path}.pub"
        return 0
    fi

    echo "Generating ed25519 SSH key for: $purpose"
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$comment"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"

    # Also install to runtime dir
    install_key "$key_path"

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Key generated successfully!"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "Private key (persistent): $key_path"
    echo "Runtime copy:             $SSH_RUNTIME_DIR/$(basename "$key_path")"
    echo ""
    echo "Public key (copy this):"
    echo "────────────────────────────────────────"
    cat "${key_path}.pub"
    echo "────────────────────────────────────────"

    if [ "$purpose" = "git" ]; then
        echo ""
        echo "NEXT STEPS:"
        echo "  1. Copy the public key above"
        echo "  2. Go to GitHub → Settings → SSH and GPG Keys → New SSH Key"
        echo "     (or GitLab/Gitea equivalent)"
        echo "  3. Paste the key and save"
        echo "  4. Come back here and click 'Initialize Repo'"
    elif [ "$purpose" = "haos" ]; then
        echo ""
        echo "NEXT STEPS:"
        echo "  1. Copy the public key above"
        echo "  2. In Home Assistant, go to:"
        echo "     Settings → Add-ons → Advanced SSH & Web Terminal → Configuration"
        echo "  3. Under 'Authorized keys', paste the public key"
        echo "  4. Restart the SSH add-on"
        echo "  5. Come back here and click 'Dry Run' to test the connection"
    fi
}

install_key() {
    local key_path="$1"
    local key_name
    key_name=$(basename "$key_path")

    if [ -f "$key_path" ]; then
        cp -p "$key_path" "$SSH_RUNTIME_DIR/$key_name"
        cp -p "${key_path}.pub" "$SSH_RUNTIME_DIR/${key_name}.pub"
        chmod 600 "$SSH_RUNTIME_DIR/$key_name"
    fi
}

install_all_keys() {
    # Copy all plugin SSH keys from USB to /root/.ssh/
    local count=0
    for key in "$SSH_PERSIST_DIR"/*; do
        [ -f "$key" ] || continue
        # Skip .pub files (they're copied alongside private keys)
        [[ "$key" == *.pub ]] && continue

        install_key "$key"
        count=$((count + 1))
    done

    # Ensure SSH config entries exist for our keys
    local ssh_config="$SSH_RUNTIME_DIR/config"
    touch "$ssh_config"
    chmod 600 "$ssh_config"

    # Add git key config if not present
    if [ -f "$GIT_KEY" ] && ! grep -q "# git-backup-git" "$ssh_config" 2>/dev/null; then
        cat >> "$ssh_config" << EOF

# git-backup-git
Host github.com gitlab.com bitbucket.org
    IdentityFile $SSH_RUNTIME_DIR/git_backup_key
    StrictHostKeyChecking accept-new
EOF
    fi

    # Add HAOS key config if not present
    if [ -f "$HAOS_KEY" ] && ! grep -q "# git-backup-haos" "$ssh_config" 2>/dev/null; then
        # Read HAOS host from config if available
        local haos_host="homeassistant.local"
        local cfg="/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
        if [ -f "$cfg" ]; then
            source "$cfg"
            haos_host="${HAOS_HOST:-homeassistant.local}"
        fi

        cat >> "$ssh_config" << EOF

# git-backup-haos
Host $haos_host
    IdentityFile $SSH_RUNTIME_DIR/haos_backup_key
    StrictHostKeyChecking accept-new
EOF
    fi

    [ "$count" -gt 0 ] && echo "Installed $count SSH key(s) to $SSH_RUNTIME_DIR"
}

show_key() {
    local purpose="$1"
    local key_path

    case "$purpose" in
        git)  key_path="$GIT_KEY" ;;
        haos) key_path="$HAOS_KEY" ;;
        *)    echo "Usage: $0 show {git|haos}"; exit 1 ;;
    esac

    if [ ! -f "${key_path}.pub" ]; then
        echo "No $purpose key found. Generate one first."
        exit 1
    fi

    echo "Public key ($purpose):"
    echo "────────────────────────────────────────"
    cat "${key_path}.pub"
    echo "────────────────────────────────────────"
}

case "${1:-}" in
    git)
        generate_key "git" "$GIT_KEY"
        ;;
    haos)
        generate_key "haos" "$HAOS_KEY"
        ;;
    install)
        install_all_keys
        ;;
    show)
        show_key "${2:-}"
        ;;
    *)
        echo "Usage: $0 {git|haos|install|show git|show haos}"
        echo ""
        echo "  git      Generate SSH key for git remote push"
        echo "  haos     Generate SSH key for Home Assistant OS"
        echo "  install  Copy keys from USB to /root/.ssh/ (run on boot)"
        echo "  show     Display a public key"
        exit 1
        ;;
esac
