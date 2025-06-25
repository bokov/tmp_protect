#!/bin/bash
set -euo pipefail
#set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/tmp_protect_config.json"
CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=true  # Always forced to true for now
DEBUG_LEVEL=1

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
MATCH_GIT_STATUS=$(jq -r '.global.match_git_status // empty' "$CONFIG_FILE")

readarray -t UID_LIST < <(jq -r '.global.uids[]' "$CONFIG_FILE")
now=$(date +%s)
declare -A DIR_SEEN
DIR_SEEN["xxyyzz"]=1
[[ $DEBUG_LEVEL -ge 3 ]] && echo "created seen dirs: ${#DIR_SEEN[@]}"

# --- Helpers ---
safe_stat_size() { stat -c%s "$1" 2>/dev/null || return 1; }
safe_stat_mtime() { stat -c%Y "$1" 2>/dev/null || return 1; }
safe_stat_uid() { stat -c%u "$1" 2>/dev/null || return 1; }
is_readable_file() { [[ -f "$1" && -r "$1" ]]; }

log_entry() {
  # Format: section, inclusion-criteria-failed, exclusion-criteria-met, size, owner, age, source-path, destination-path
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$@"
}

handle_path_action() {
    local section="$1"
    local action="$2"
    local path="$3"
    local criteria_failed="${4:-}"
    local excluded_reason="${5:-}"
    local criteria_met="${6:-true}"  # default to true

    local now="${now:-$(date +%s)}"
    local uid size mtime age dest_path

    uid=$(stat -c %u "$path")
    size=$(du -sb "$path" 2>/dev/null | cut -f1 || echo 0)
    mtime=$(safe_stat_mtime "$path" || echo 0)
    age=$((now - mtime))
    dest_path="$DEST_DIR/${path#$SOURCE_DIR/}"

    if [[ "$action" == "move" && "$criteria_met" == "true" ]]; then
        if $DRY_RUN; then
            echo "[dry-run] would move: $path → $dest_path"
        else
            mkdir -p "$(dirname "$dest_path")"
            mv "$path" "$dest_path"
            echo "Moved: $path → $dest_path"
        fi
    else
        dest_path=""
    fi

    log_entry "$section" "$criteria_failed" "$excluded_reason" "$size" "$uid" "$age" "$path" "$dest_path"
}

# Get top-level subdirectories of SOURCE_DIR
#readarray -t candidate_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d)
if [[ "${#UID_LIST[@]}" -eq 0 ]]; then
  # No UID restriction
  readarray -t candidate_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d ! -empty)
else
  # Build an OR pattern for UID filter
  uid_expr=()
  for uid in "${UID_LIST[@]}"; do
    uid_expr+=("-uid" "$uid" "-o")
  done
  unset 'uid_expr[-1]'  # Remove trailing -o
  echo "${uid_expr[@]}"
  readarray -t candidate_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d \( "${uid_expr[@]}" \) ! -empty )  
fi

# below commented out because it's causing non-empty directories to be dropped
# # remove directories that contain only empty directory hierarchies
# for i in "${!candidate_dirs[@]}"; do
#   dir="${candidate_dirs[$i]}"
#   if ! find "$dir" -mindepth 1 | grep -q .; then
#     unset 'candidate_dirs[i]'
#   fi
# done
# # reindex array to remove gaps
# candidate_dirs=("${candidate_dirs[@]}")

# echo "Checking for airworld2 and uphouse"
# [[ "${candidate_dirs[*]}" =~ /airworld2($|[[:space:]]) ]] && echo "airworld2 present"
# [[ "${candidate_dirs[*]}" =~ /uphouse($|[[:space:]]) ]] && echo "uphouse present"

[[ $DEBUG_LEVEL -ge 3 ]] && echo "initial seen dirs: ${#DIR_SEEN[@]}"

# --- loop through and handle git directories ---
for dir_path in "${candidate_dirs[@]}"; do

    # Git protection logic (global)
    if [[ -n "$MATCH_GIT_STATUS" && -d "$dir_path/.git" ]]; then
        is_dirty=false
        is_ahead=false
        DIR_SEEN["$dir_path"]=1
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "git: adding $dir_path to seen dirs: ${#DIR_SEEN[@]}"; 

        if git -C "$dir_path" status --porcelain 2>/dev/null | grep -q '^[ M?]'; then
            is_dirty=true
        fi

        if git -C "$dir_path" rev-parse --abbrev-ref HEAD &>/dev/null; then
            ahead_count=$(git -C "$dir_path" rev-list --count --right-only origin/HEAD...HEAD 2>/dev/null || echo -1)
            [[ "$ahead_count" != "0" ]] && is_ahead=true
        fi

        git_verdict="git"
        match=false

        [[ "$MATCH_GIT_STATUS" == *dirty* && "$is_dirty" == true ]] && match=true && git_verdict+="-dirty"
        [[ "$MATCH_GIT_STATUS" == *ahead* && "$is_ahead" == true ]] && match=true && git_verdict+="-ahead"
        [[ "$git_verdict" == "git" ]] && git_verdict+="-clean"

        # if [[ "$MATCH_GIT_STATUS" == *dirty* && "$is_dirty" == true ]]; then
        #     match=true
        #     git_verdict+="-dirty"
        # fi

        # if [[ "$MATCH_GIT_STATUS" == *ahead* && "$is_ahead" == true ]]; then
        #     match=true
        #     git_verdict+="-ahead"
        # fi


        [[ "$match" == true ]] && handle_path_action "git" "move" "$dir_path" "" "$git_verdict" && continue

        # if [[ "$match" == true ]]; then
        #     dest_path="$DEST_DIR/${dir_path#$SOURCE_DIR/}"
        #     if $DRY_RUN; then
        #         echo "[dry-run] would move git repo: $dir_path → $dest_path"
        #     else
        #         mkdir -p "$dest_path"
        #         cp -a "$dir_path" "$dest_path/.."
        #         echo "Moved git repo: $dir_path → $dest_path"
        #     fi
        #     log_entry "git" "" "$git_verdict" "" "" "" "$dir_path" "$dest_path"
        # else
        #     log_entry "git" "" "git-clean" "" "" "" "$dir_path" ""
        # fi

        # continue  # Always skip further processing of Git repos
    fi
    [[ $DEBUG_LEVEL -ge 3 ]] && echo "git $dir_path seen dirs: ${#DIR_SEEN[@]}"
done

[[ $DEBUG_LEVEL -ge 3 ]] && echo "before sections seen dirs: ${#DIR_SEEN[@]}"

# --- Loop through all sections ---
while read -r section; do
    section_path=".section[\"$section\"]"

    # Read all supported fields, defaulting to empty or safe values
    action=$(jq -r "$section_path.action // \"log\"" "$CONFIG_FILE")
    match_dir=$(jq -r "$section_path.match_dir // empty" "$CONFIG_FILE")
    readarray -t match_contents < <(jq -r "$section_path.match_contents // empty | .[]" "$CONFIG_FILE")
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

    #echo " match_contents: ${match_contents[*]}"

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

    # Only act on sections that use match_dir or match_contents (regex mode)
    [[ -n "$match_dir" || "${#match_contents[@]}" -gt 0 ]] || continue

    [[ $DEBUG_LEVEL -ge 2 ]] && echo "Section [$section] looking for directories matching criteria" 

    # Loop through all candidate directories and apply rule if they match
    for dir_path in "${candidate_dirs[@]}"; do

        # if this directory has already been seen, don't bother with any other
        # steps
        if [[ -n "${DIR_SEEN[$dir_path]:-}" ]]; then
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "$section: $dir_path already seen"
            continue
        fi


        # Check match_dir
        dir_matches=false
        if [[ -n "$match_dir" && "$dir_path" =~ $match_dir ]]; then
            dir_matches=true
        fi

        contents_match=false
        if [[ "${#match_contents[@]}" -gt 0 ]]; then
            all_found=true
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "starting contents_match on $dir_path"
            for regex in "${match_contents[@]}"; do
                # For each required pattern, make sure at least one match exists in the directory
                if ! find "$dir_path" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -qE "$regex"; then
                    all_found=false
                    break
                fi
            done
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "ending contents_match on $dir_path"
            $all_found && contents_match=true
        fi

        if [[ "$dir_matches" == true || "$contents_match" == true ]];  then
            DIR_SEEN["$dir_path"]=1
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "$section: adding $dir_path to seen dirs: ${#DIR_SEEN[@]}"; 
            
            # ignore is for known temp stuff that doesn't need to show up in the 
            # log just keep going without logging... also, the presence of 
            # ignore overrides any inclusion or exclusion criteria-- why would
            # you match files just for the purpose of ignoring them? 
            if [[ "$action" == "ignore" ]]; then
                continue
            fi

            if [[ ! -d "$dir_path" ]]; then
                echo "  [!] Skipped: $dir_path does not exist or is not a directory"
                continue
            fi
            
            [[ $DEBUG_LEVEL -ge 2 ]] && echo "  → Applying rules from [$section] to $dir_path"

            if ! $has_criteria; then
                # Whole-directory mode
                handle_path_action "$section" "$action" "$dir_path"

                # size=$(du -sb "$dir_path" 2>/dev/null | cut -f1 || echo 0)
                # mtime=$(safe_stat_mtime "$dir_path" || echo 0)
                # age=$((now - mtime))
                # dest_path="$DEST_DIR/${dir_path#$SOURCE_DIR/}"

                # if [[ "$action" == "move" ]]; then
                #     if $DRY_RUN; then
                #         echo "[dry-run] would move directory: $dir_path → $dest_path"
                #     else
                #         mkdir -p "$(dirname "$dest_path")"
                #         mv "$dir_path" "$dest_path"
                #         echo "Moved directory: $dir_path → $dest_path"
                #     fi
                # else
                #     dest_path=""
                # fi

                # log_entry "$section" "" "" "$size" "$uid" "$age" "$dir_path" "$dest_path"
            else

                # File-level logic (only reached if has_criteria=true)
                find "$dir_path" -mindepth 1 -maxdepth 1 -type f | while read -r path; do
                    #name=$(basename "$path")
                    if ! is_readable_file "$path"; then
                        log_entry "$section" "unreadable" "" "" "" "" "$path" ""
                        continue
                    fi
                    
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
                            excluded_reason+="age>${max_age}d|"
                        fi
                    fi

                    # Apply min-age filter (if defined)
                    if [[ -n "$min_age" ]]; then
                        cutoff_seconds=$((min_age * 86400))
                        if (( age < cutoff_seconds )); then
                            excluded_reason+="age<${min_age}d|"
                        fi
                    fi

                    criteria_met=$([[ -z $excluded_reason ]] && echo "true" || echo "false" )

                    # Handle action
                    handle_path_action "$section" "$action" "$path" "$criteria_failed" "$excluded_reason" "$criteria_met"

                    # if [[ "$action" == "move" && -z "$excluded_reason" ]]; then
                    #     rel_path="${path#$SOURCE_DIR/}"  # relative to source
                    #     dest_path="$DEST_DIR/$rel_path"

                    #     if $DRY_RUN; then
                    #         echo "[dry-run] would move: $path → $dest_path"
                    #     else
                    #         mkdir -p "$(dirname "$dest_path")"
                    #         mv "$path" "$dest_path"
                    #         echo "Moved: $path → $dest_path"
                    #     fi
                    # else
                    #     # Not eligible for move, or action is 'log'
                    #     dest_path="" 
                    # fi

                    # log_entry "$section" "$criteria_failed" "$excluded_reason" "$size" "$uid" "$age" "$path" "$dest_path"


                done
        
            fi         
        
        fi
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "dir $dir_path seen dirs: ${#DIR_SEEN[@]}"
    done    
    [[ $DEBUG_LEVEL -ge 3 ]] && echo "section $section seen dirs: ${#DIR_SEEN[@]}"
done < <(jq -r '.section | keys[]' "$CONFIG_FILE")

[[ $DEBUG_LEVEL -ge 3 ]] && echo "before unmatched seen dirs: ${#DIR_SEEN[@]}"

# --- Handle unmatched top-level dirs if configured ---
if jq -e '.unmatched_dirs' "$CONFIG_FILE" > /dev/null; then
  unmatched_action=$(jq -r '.unmatched_dirs.action // "log"' "$CONFIG_FILE")

  #readarray -t all_top_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d)
  [[ $DEBUG_LEVEL -ge 3 ]] && echo "start of unmatched seen dirs: ${#DIR_SEEN[@]}"

  for dir_path in "${candidate_dirs[@]}"; do
    if [[ -n "${DIR_SEEN[$dir_path]:-}" ]]; then 
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "unmatched: $dir_path already seen"
        continue
    fi

    handle_path_action "unmached_dirs" "$unmatched_action" "$dir_path"

    # dest_path="$DEST_DIR/${dir_path#$SOURCE_DIR/}"
    # if [[ "$unmatched_action" == "move" ]]; then
    #     if $DRY_RUN; then
    #         echo "[dry-run] would move unmatched dir: $dir_path → $dest_path"
    #     else
    #         mkdir -p "$dest_path"
    #         cp -a "$dir_path" "$dest_path/.."
    #         echo "Moved unmatched dir: $dir_path → $dest_path"
    #     fi
    # else
    #     dest_path=""
    # fi
    # log_entry "unmatched_dirs" "" "unmatched" "" "" "" "$dir_path" "$dest_path"
  done
fi
