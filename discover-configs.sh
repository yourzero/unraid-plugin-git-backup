#!/bin/bash
# discover-configs.sh
# Scans Unraid appdata directories to find likely config files/dirs per container.
# Run on Unraid: bash discover-configs.sh [appdata_path]

APPDATA_ROOT="${1:-/mnt/user/appdata}"

# Config file extensions (case-insensitive matching)
CONFIG_EXTENSIONS=(
    conf cfg ini yml yaml json xml toml env
    properties htpasswd htaccess crontab
    ovpn pem crt key
)

# Directory names that typically hold config
CONFIG_DIR_NAMES=(
    config configuration conf settings
    custom-cont-init.d custom-services.d
    nginx ssl certs keys
    templates rules
)

# Known large/data patterns to flag (not config)
DATA_PATTERNS=(
    "*.db" "*.sqlite" "*.sqlite3" "*.db-shm" "*.db-wal"
    "*.log" "*.log.*"
    "cache/*" "Cache/*" "logs/*" "Logs/*"
    "*.jpg" "*.png" "*.gif" "*.mp4" "*.mkv"
    "thumbnails/*" "Thumbnails/*" "thumb/*"
    "*.sock" "*.pid"
)

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

hr() { printf '%*s\n' 70 '' | tr ' ' '─'; }

human_size() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1048576 )); then
        echo "$(( bytes / 1024 ))K"
    elif (( bytes < 1073741824 )); then
        echo "$(( bytes / 1048576 ))M"
    else
        echo "$(( bytes / 1073741824 ))G"
    fi
}

if [ ! -d "$APPDATA_ROOT" ]; then
    echo -e "${RED}Error: $APPDATA_ROOT not found.${NC}"
    echo "Usage: $0 [/path/to/appdata]"
    exit 1
fi

echo -e "${BOLD}Unraid Appdata Config Discovery${NC}"
echo -e "Scanning: ${BLUE}$APPDATA_ROOT${NC}"
hr

total_apps=0
total_config_files=0
total_config_bytes=0
total_data_bytes=0

for app_dir in "$APPDATA_ROOT"/*/; do
    [ -d "$app_dir" ] || continue
    app_name=$(basename "$app_dir")
    ((total_apps++))

    echo ""
    echo -e "${BOLD}${BLUE}[$app_name]${NC}"

    config_files=()
    config_bytes=0
    data_files=()
    data_bytes=0
    other_files=()
    other_bytes=0

    # Prune known-heavy directories to avoid crawling millions of files
    PRUNE_DIRS=(
        "cache" "Cache" "CacheClip" "Crash Reports"
        "logs" "Logs" "log"
        "thumbnails" "Thumbnails" "thumb" "Thumb"
        "Codecs" "Updates" "Diagnostics"
        "Media" "media" "Metadata" "metadata"
        "node_modules" ".git" "__pycache__"
        "Plug-in Support" "Plugin Support"
    )
    prune_args=()
    for pd in "${PRUNE_DIRS[@]}"; do
        prune_args+=(-name "$pd" -prune -o)
    done

    # Walk the app directory (pruning heavy dirs)
    while IFS= read -r -d '' file; do
        rel_path="${file#$app_dir}"
        filename=$(basename "$file")
        extension="${filename##*.}"
        extension_lower=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)

        # Check if it matches a data pattern
        is_data=false
        for pattern in "${DATA_PATTERNS[@]}"; do
            # Simple glob match against relative path
            if [[ "$rel_path" == $pattern ]] || [[ "$filename" == $pattern ]]; then
                is_data=true
                break
            fi
        done

        if $is_data; then
            data_files+=("$rel_path")
            ((data_bytes += size))
            continue
        fi

        # Check if it's in a config-named directory
        in_config_dir=false
        for dir_name in "${CONFIG_DIR_NAMES[@]}"; do
            if [[ "$rel_path" == "$dir_name/"* ]] || [[ "$rel_path" == *"/$dir_name/"* ]]; then
                in_config_dir=true
                break
            fi
        done

        # Check if extension matches config patterns
        is_config_ext=false
        for ext in "${CONFIG_EXTENSIONS[@]}"; do
            if [[ "$extension_lower" == "$ext" ]]; then
                is_config_ext=true
                break
            fi
        done

        # Check for dotfiles that are often config (e.g., .gitconfig, .env)
        is_dotfile=false
        if [[ "$filename" == .* ]] && (( size < 102400 )); then
            is_dotfile=true
        fi

        # Check for common config filenames without extensions
        is_config_name=false
        config_names=("Dockerfile" "docker-compose" "Caddyfile" "Makefile" "Procfile" "Gemfile" "Rakefile")
        for cn in "${config_names[@]}"; do
            if [[ "$filename" == "$cn" ]]; then
                is_config_name=true
                break
            fi
        done

        # Classify: config if extension matches, in config dir, or small text-like file
        if $is_config_ext || $in_config_dir || $is_dotfile || $is_config_name; then
            config_files+=("$rel_path|$size")
            ((config_bytes += size))
        elif (( size < 51200 )); then
            # Small files are likely config — classify by size alone
            # (avoids expensive `file --mime-type` fork per file)
            config_files+=("$rel_path|$size")
            ((config_bytes += size))
        else
            other_files+=("$rel_path|$size")
            ((other_bytes += size))
        fi

    done < <(find "$app_dir" "${prune_args[@]}" -type f -print0 2>/dev/null)

    # Count config directories
    config_dir_count=0
    config_dir_list=()
    while IFS= read -r -d '' dir; do
        dir_name=$(basename "$dir")
        dir_name_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')
        for cn in "${CONFIG_DIR_NAMES[@]}"; do
            if [[ "$dir_name_lower" == "$cn" ]]; then
                config_dir_list+=("${dir#$app_dir}")
                ((config_dir_count++))
                break
            fi
        done
    done < <(find "$app_dir" -type d -print0 2>/dev/null)

    # Report
    if (( ${#config_dir_list[@]} > 0 )); then
        echo -e "  ${GREEN}Config dirs:${NC}"
        for d in "${config_dir_list[@]}"; do
            echo -e "    ${GREEN}📁 $d/${NC}"
        done
    fi

    if (( ${#config_files[@]} > 0 )); then
        echo -e "  ${GREEN}Config files (${#config_files[@]} files, $(human_size $config_bytes)):${NC}"
        # Show up to 15 files, sorted by path
        shown=0
        for entry in $(printf '%s\n' "${config_files[@]}" | sort -t'|' -k1); do
            path="${entry%%|*}"
            size="${entry##*|}"
            if (( shown < 15 )); then
                echo -e "    ${GREEN}✓${NC} $path ${GRAY}($(human_size $size))${NC}"
            fi
            ((shown++))
        done
        if (( shown > 15 )); then
            echo -e "    ${GRAY}... and $((shown - 15)) more${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ No config files detected${NC}"
    fi

    if (( ${#data_files[@]} > 0 )); then
        echo -e "  ${RED}Data/skip (${#data_files[@]} files, $(human_size $data_bytes)):${NC}"
        # Just show count by type
        declare -A data_type_counts
        for df in "${data_files[@]}"; do
            ext="${df##*.}"
            ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
            ((data_type_counts[$ext_lower]++))
        done
        for ext in $(echo "${!data_type_counts[@]}" | tr ' ' '\n' | sort); do
            echo -e "    ${RED}✗${NC} *.${ext} (${data_type_counts[$ext]} files)"
        done
        unset data_type_counts
    fi

    if (( ${#other_files[@]} > 0 )); then
        echo -e "  ${YELLOW}Other (${#other_files[@]} files, $(human_size $other_bytes)):${NC}"
        # Summarize by extension
        declare -A other_ext_counts
        declare -A other_ext_bytes
        for entry in "${other_files[@]}"; do
            path="${entry%%|*}"
            size="${entry##*|}"
            ext="${path##*.}"
            ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
            ((other_ext_counts[$ext_lower]++))
            ((other_ext_bytes[$ext_lower] += size))
        done
        for ext in $(echo "${!other_ext_counts[@]}" | tr ' ' '\n' | sort); do
            echo -e "    ${YELLOW}?${NC} *.${ext} (${other_ext_counts[$ext]} files, $(human_size ${other_ext_bytes[$ext]}))"
        done
        unset other_ext_counts other_ext_bytes
    fi

    ((total_config_files += ${#config_files[@]}))
    ((total_config_bytes += config_bytes))
    ((total_data_bytes += data_bytes + other_bytes))
done

hr
echo ""
echo -e "${BOLD}Summary${NC}"
echo -e "  Apps scanned:    $total_apps"
echo -e "  Config files:    ${GREEN}$total_config_files${NC} ($(human_size $total_config_bytes))"
echo -e "  Data/other:      ${RED}$(human_size $total_data_bytes)${NC} (excluded)"
echo ""
echo -e "${GRAY}Tip: Review output above. Adjust CONFIG_EXTENSIONS and DATA_PATTERNS"
echo -e "at the top of this script to tune detection for your containers.${NC}"
