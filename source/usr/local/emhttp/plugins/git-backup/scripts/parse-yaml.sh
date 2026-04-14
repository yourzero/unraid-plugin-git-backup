#!/bin/bash
# parse-yaml.sh — Minimal YAML parser for the container knowledge base
#
# This is NOT a general-purpose YAML parser. It only handles the specific
# structure of container-knowledge.yml:
#   containers:
#     - name: foo
#       match_image: bar
#       match_folder: Baz
#       include:
#         - "pattern1"
#         - "pattern2"
#       exclude:
#         - "pattern3"
#       notes: ignored
#
# Output: pipe-delimited records, one per container:
#   name|match_folder|include_csv|exclude_csv
#
# Usage:
#   source parse-yaml.sh
#   while IFS='|' read -r name match_folder include_csv exclude_csv; do
#       ...
#   done < <(parse_yaml_containers "/path/to/container-knowledge.yml")

parse_yaml_containers() {
    local file="$1"
    [ -f "$file" ] || { echo "ERROR: File not found: $file" >&2; return 1; }

    local name="" match_folder="" include_list="" exclude_list=""
    local current_list=""  # tracks whether we're collecting "include" or "exclude" items

    _emit_record() {
        # Only emit if we have a name
        [ -z "$name" ] && return

        # Strip trailing commas
        include_list="${include_list%,}"
        exclude_list="${exclude_list%,}"

        echo "${name}|${match_folder}|${include_list}|${exclude_list}"
    }

    _strip_quotes() {
        local val="$1"
        # Remove surrounding quotes (single or double)
        val="${val#\"}" ; val="${val%\"}"
        val="${val#\'}" ; val="${val%\'}"
        echo "$val"
    }

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Detect new container entry: "  - name: value"
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+name:[[:space:]]*(.*) ]]; then
            # Emit previous record
            _emit_record

            # Reset for new record
            name=$(_strip_quotes "${BASH_REMATCH[1]}")
            match_folder=""
            include_list=""
            exclude_list=""
            current_list=""
            continue
        fi

        # Scalar fields (only within a container entry)
        if [[ "$line" =~ ^[[:space:]]+match_folder:[[:space:]]*(.*) ]]; then
            local val="${BASH_REMATCH[1]}"
            if [ "$val" = "null" ] || [ -z "$val" ]; then
                match_folder=""
            else
                match_folder=$(_strip_quotes "$val")
            fi
            current_list=""
            continue
        fi

        # We skip match_image — not needed for folder-based matching in backup
        if [[ "$line" =~ ^[[:space:]]+match_image: ]]; then
            current_list=""
            continue
        fi

        # Notes field — skip (can be multi-line with >)
        if [[ "$line" =~ ^[[:space:]]+notes: ]]; then
            current_list=""
            continue
        fi

        # List field headers
        if [[ "$line" =~ ^[[:space:]]+include:[[:space:]]*(.*) ]]; then
            local rest="${BASH_REMATCH[1]}"
            # Handle inline empty list: "include: []"
            if [ "$rest" = "[]" ]; then
                include_list=""
                current_list=""
            else
                current_list="include"
            fi
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]+exclude:[[:space:]]*(.*) ]]; then
            local rest="${BASH_REMATCH[1]}"
            if [ "$rest" = "[]" ]; then
                exclude_list=""
                current_list=""
            else
                current_list="exclude"
            fi
            continue
        fi

        # List items: "      - "pattern""
        if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]] && [ -n "$current_list" ]; then
            local item=$(_strip_quotes "${BASH_REMATCH[1]}")
            if [ "$current_list" = "include" ]; then
                include_list="${include_list}${item},"
            elif [ "$current_list" = "exclude" ]; then
                exclude_list="${exclude_list}${item},"
            fi
            continue
        fi

    done < "$file"

    # Emit the last record
    _emit_record
}
