#!/bin/bash
set -euo pipefail
#set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/tmp_protect_config.json"
CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=true  # Always forced to true for now

# --- Parse options ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      echo "(--dry-run detected, but dry-run is forced to true internally)"
      shift
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Prereqs ---
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

# --- Global config ---
SOURCE_DIR=$(jq -r '.global.source_dir' "$CONFIG_FILE")
DEST_DIR=$(jq -r '.global.destination_dir' "$CONFIG_FILE")
readarray -t UID_LIST < <(jq -r '.global.uids[]' "$CONFIG_FILE")
now=$(date +%s)


# --- Helpers ---
safe_stat_size() { stat -c%s "$1" 2>/dev/null || return 1; }
safe_stat_mtime() { stat -c%Y "$1" 2>/dev/null || return 1; }
safe_stat_uid() { stat -c%u "$1" 2>/dev/null || return 1; }
is_readable_file() { [[ -f "$1" && -r "$1" ]]; }

log_entry() {
  # Format: section, inclusion-criteria-failed, exclusion-criteria-met, size, owner, age, source-path, destination-path
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$@"
}

# --- Loop through all sections ---
jq -r '.section | keys[]' "$CONFIG_FILE" | while read -r section; do
    section_path=".section[\"$section\"]"

    # Read all supported fields, defaulting to empty or safe values
    action=$(jq -r "$section_path.action // \"log\"" "$CONFIG_FILE")
    match_dir=$(jq -r "$section_path.match_dir // empty" "$CONFIG_FILE")
    ext_whitelist=$(jq -r "$section_path.extensions_whitelist // empty | @sh" "$CONFIG_FILE")
    ext_blacklist=$(jq -r "$section_path.extensions_blacklist // empty | @sh" "$CONFIG_FILE")
    regex_whitelist=$(jq -r "$section_path.regexp_whitelist // empty | @sh" "$CONFIG_FILE")
    regex_blacklist=$(jq -r "$section_path.regexp_blacklist // empty | @sh" "$CONFIG_FILE")
    max_age=$(jq -r "$section_path.\"max-age\" // empty" "$CONFIG_FILE")
    min_age=$(jq -r "$section_path.\"min-age\" // empty" "$CONFIG_FILE")
    max_size=$(jq -r "$section_path.\"max-size\" // empty" "$CONFIG_FILE")
    min_size=$(jq -r "$section_path.\"min-size\" // empty" "$CONFIG_FILE")
    priority=$(jq -r "$section_path.\"prioritize-by\" // empty | @sh" "$CONFIG_FILE")
    size_limit=$(jq -r "$section_path.\"size-limit\" // empty" "$CONFIG_FILE")
    num_limit=$(jq -r "$section_path.\"num-limit\" // empty" "$CONFIG_FILE")

    # Determine if this section has any inclusion/exclusion criteria
    has_criteria=false
    for key in ext_whitelist ext_blacklist regex_whitelist regex_blacklist max_age min_age max_size min_size num_limit size_limit; do
        val=$(eval echo \$$key)
        if [[ -n "$val" ]]; then
            has_criteria=true
            break
        fi
    done
    
    # Convert JSON stringified lists to bash arrays
    eval "ext_whitelist=($ext_whitelist)"
    eval "ext_blacklist=($ext_blacklist)"
    eval "regex_whitelist=($regex_whitelist)"
    eval "regex_blacklist=($regex_blacklist)"
    eval "priority=($priority)"


    # Get top-level subdirectories of SOURCE_DIR
    readarray -t candidate_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d)

    # Only act on sections that use match_dir (regex mode)
    [[ -n "$match_dir" ]] || continue

    echo "Section [$section] looking for directories matching regex: $match_dir"

    # Loop through all candidate directories and apply rule if they match
    for dir_path in "${candidate_dirs[@]}"; do
        if [[ "$dir_path" =~ $match_dir ]]; then
            echo "  → Applying rules from [$section] to $dir_path"

            if [[ ! -d "$dir_path" ]]; then
            echo "  [!] Skipped: $dir_path does not exist or is not a directory"
            continue
            fi

            find "$dir_path" -mindepth 1 -maxdepth 1 -type f | while read -r path; do
            name=$(basename "$path")

                if ! is_readable_file "$path"; then
                    log_entry "$section" "unreadable" "" "" "" "" "$path" ""
                    continue
                fi

                #uid=$(safe_stat_uid "$path" || echo "?")
                #[[ " ${UID_LIST[*]} " =~ " $uid " ]] || continue

                if ! uid=$(safe_stat_uid "$path"); then
                    uid="?"
                fi
                uid_allowed=false
                for allowed_uid in "${UID_LIST[@]}"; do
                    if [[ "$uid" == "$allowed_uid" ]]; then
                        uid_allowed=true
                        break
                    fi
                done
                $uid_allowed || continue


                
                size=$(safe_stat_size "$path" || echo 0)
                mtime=$(safe_stat_mtime "$path" || echo 0)
                age=$((now - mtime))



                # Determine exclusion/inclusion criteria
                criteria_failed=""
                excluded_reason=""
                dest_path=""

                # Apply max-age filter (if defined)
                if [[ -n "$max_age" ]]; then
                    cutoff_seconds=$((max_age * 86400))
                    if (( age > cutoff_seconds )); then
                        excluded_reason="age>${max_age}d"
                    fi
                fi

                # Handle action
                if [[ "$action" == "move" && -z "$excluded_reason" ]]; then
                    rel_path="${path#$SOURCE_DIR/}"  # relative to source
                    dest_path="$DEST_DIR/$rel_path"

                    if $DRY_RUN; then
                        echo "[dry-run] would move: $path → $dest_path"
                    else
                        mkdir -p "$(dirname "$dest_path")"
                        mv "$path" "$dest_path"
                        echo "Moved: $path → $dest_path"
                    fi
                else
                    # Not eligible for move, or action is 'log'
                    :
                fi

                log_entry "$section" "$criteria_failed" "$excluded_reason" "$size" "$uid" "$age" "$path" "$dest_path"




            done
        fi
    done
done 