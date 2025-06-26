#!/bin/bash
set -euo pipefail
#set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/tmp_protect_config.json"
CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=true  # Always forced to true for now
DEBUG_LEVEL=0

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
# this is to track which directories have been handled so they are not handled
# by other rules
declare -A DIR_SEEN
DIR_SEEN["xxyyzz"]=1
[[ $DEBUG_LEVEL -ge 3 ]] && echo "created seen files: ${#DIR_SEEN[@]}"
# this is to ensure that each rule is only run once on the top level directory
declare -A TOPLEVEL_SECTIONS
TOPLEVEL_SECTIONS["xxyyzz"]=1

# --- Helpers ---
safe_stat_size() { stat -c%s "$1" 2>/dev/null || return 1; }
safe_stat_mtime() { stat -c%Y "$1" 2>/dev/null || return 1; }
safe_stat_uid() { stat -c%u "$1" 2>/dev/null || return 1; }
is_readable_file() { [[ -r "$1" ]]; }

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

[[ $DEBUG_LEVEL -ge 3 ]] && echo "initial seen files: ${#DIR_SEEN[@]}"

# --- loop through and handle git directories ---
for dir_path in "${candidate_dirs[@]}"; do

    # Git protection logic (global)
    if [[ -n "$MATCH_GIT_STATUS" ]]; then
        is_dirty=false; is_ahead=false
        if [[ -d "$dir_path/.git" ]]; then
            git_type="normal"
            if git -C "$dir_path" status --porcelain 2>/dev/null | grep -q '^[ DM?]'; then
                is_dirty=true
            fi
            if git -C "$dir_path" rev-parse --abbrev-ref HEAD &>/dev/null; then
                ahead_count=$(git -C "$dir_path" rev-list --count --right-only origin/HEAD...HEAD 2>/dev/null || echo -1)
                [[ "$ahead_count" != "0" ]] && is_ahead=true
            fi
        elif [[ -f "$dir_path/HEAD" && -d "$dir_path/refs" && -d "$dir_path/objects" ]]; then 
            git_type="bare"
            # can't do dirty but can check for ahead, but requires more complicated code
            # so treating all bare git repos as ahead for now
            is_ahead=true
        else
            git_type="none"
            continue
        fi

        # since we got past the previous statement, this is definitely some type of git repo
        DIR_SEEN["$dir_path"]=1
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "git: adding $dir_path to seen files: ${#DIR_SEEN[@]}"; 


        git_verdict="git"
        match=false
        [[ "$MATCH_GIT_STATUS" == *dirty* && "$is_dirty" == true ]] && match=true && git_verdict+="-dirty"
        [[ "$MATCH_GIT_STATUS" == *ahead* && "$is_ahead" == true ]] && match=true && git_verdict+="-ahead"
        [[ "$git_verdict" == "git" ]] && git_verdict+="-clean"
        handle_path_action "git" "move" "$dir_path" "" "$git_verdict" "$match" && continue
        # Always skip further processing of Git repos
    fi
    [[ $DEBUG_LEVEL -ge 3 ]] && echo "git $dir_path seen files: ${#DIR_SEEN[@]}"
done

[[ $DEBUG_LEVEL -ge 3 ]] && echo "before sections seen files: ${#DIR_SEEN[@]}"

# --- Loop through all sections ---
while read -r section; do
    section_path=".section[\"$section\"]"
    skip=$(jq -r "$section_path.skip // empty" "$CONFIG_FILE")
    # skip is the setting to "comment out" any section
    [[ -n "$skip" ]] && continue

    # Read all supported fields, defaulting to empty or safe values
    action=$(jq -r "$section_path.action // \"log\"" "$CONFIG_FILE")
    match_dir=$(jq -r "$section_path.match_dir // empty" "$CONFIG_FILE")
    readarray -t match_contents < <(jq -r "$section_path.match_contents // empty | .[]" "$CONFIG_FILE")
    ext_whitelist=$(jq -c "$section_path.\"extensions_whitelist\" // empty | @sh" "$CONFIG_FILE" | sed -e "s/' '/|/g" -e "s/['\"]//g")
    ext_blacklist=$(jq -c "$section_path.\"extensions_blacklist\" // empty | @sh" "$CONFIG_FILE" | sed -e "s/' '/|/g" -e "s/['\"]//g")
    regex_whitelist=$(jq -r "$section_path.regexp_whitelist // empty | @sh" "$CONFIG_FILE")
    #regex_blacklist=$(jq -c "$section_path.regexp_blacklist // empty | @sh" "$CONFIG_FILE")
    regex_blacklist=$(jq -c "$section_path.\"regexp_blacklist\" // empty | @sh" "$CONFIG_FILE" | sed -e "s/' '/|/g" -e "s/['\"]//g")
    max_age=$(jq -r "$section_path.\"max-age\" // empty" "$CONFIG_FILE")
    min_age=$(jq -r "$section_path.\"min-age\" // empty" "$CONFIG_FILE")
    max_size=$(jq -r "$section_path.\"max-size\" // empty" "$CONFIG_FILE")
    min_size=$(jq -r "$section_path.\"min-size\" // empty" "$CONFIG_FILE")
    priority=$(jq -r "$section_path.\"prioritize-by\" // empty | @sh" "$CONFIG_FILE")
    size_limit=$(jq -r "$section_path.\"size-limit\" // empty" "$CONFIG_FILE")
    num_limit=$(jq -r "$section_path.\"num-limit\" // empty" "$CONFIG_FILE")

    #echo " match_contents: ${match_contents[*]}"
    #[[ -n "$ext_whitelist" ]] && echo "ext_whitelist: $ext_whitelist";
    [[ -n "$ext_whitelist" ]] && ext_whitelist="\.($ext_whitelist)\$"
    [[ -n "$ext_blacklist" ]] && ext_blacklist="\.($ext_blacklist)\$"
    [[ -n "$regex_blacklist" ]] && echo "regex_blacklist: $regex_blacklist";

    # Determine if this section has any inclusion/exclusion criteria

    has_criteria=false
    for varset in ext_whitelist ext_blacklist regex_whitelist regex_blacklist max_age min_age max_size min_size num_limit size_limit; do
        if [[ -n "${!varset}" ]]; then
            has_criteria=true
            break
        fi
    done

    # has_criteria=false
    # for varset in ext_whitelist ext_blacklist regex_whitelist regex_blacklist max_age min_age max_size min_size num_limit size_limit; do
    #     #val=$(eval echo \$$key)
    #     if [[ -n "$varset" ]]; then
    #         has_criteria=true
    #         break
    #     fi
    # done

    # Convert JSON stringified lists to bash arrays
    #eval "ext_whitelist=($ext_whitelist)"
    #eval "ext_blacklist=($ext_blacklist)"
    #eval "regex_whitelist=($regex_whitelist)"
    #eval "regex_blacklist=($regex_blacklist)"
    eval "priority=($priority)"

    # Only act on sections that use match_dir or match_contents (regex mode)
    top_level_dir=false
    [[ -n "$match_dir" || "${#match_contents[@]}" -gt 0 ]] || top_level_dir=true

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
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "$section: adding $dir_path to seen files: ${#DIR_SEEN[@]}"; 
            # ignore is for known temp stuff that doesn't need to show up in the 
            # log just keep going without logging... also, the presence of 
            # ignore overrides any inclusion or exclusion criteria-- why would
            # you match files just for the purpose of ignoring them? 
            [[ "$action" == "ignore" ]] && continue
            [[ ! -d "$dir_path" ]] && echo "  [!] Skipped: $dir_path does not exist or is not a directory" && continue
        elif [[ "$top_level_dir" == true ]]; then # top-level files 
            dir_path=$SOURCE_DIR
            [[ -n "${TOPLEVEL_SECTIONS["$section"]:-}" ]] && continue # If this section has already been applied to the top level, don't repeat
            TOPLEVEL_SECTIONS["$section"]=1
            [[ $DEBUG_LEVEL -ge 3 ]] && echo "$section added to seen sections: ${#TOPLEVEL_SECTIONS[@]}"
        else 
            # no conditions met
            continue
        fi

        echo "whitelist: $ext_whitelist"

        if ! $has_criteria; then
            [[ $DEBUG_LEVEL -ge 2 ]] && echo "  → Applying directory rules from [$section] to $dir_path, top-level: $top_level_dir, has criteria: $has_criteria"
            # Whole-directory mode
            handle_path_action "$section" "$action" "$dir_path"
            continue
        else
            [[ $DEBUG_LEVEL -ge 2 ]] && echo "  → Applying file rules from [$section] to $dir_path, top-level: $top_level_dir, has criteria: $has_criteria"
            # File-level logic (only reached if has_criteria=true)
            find "$dir_path" -mindepth 1 -maxdepth 1 | while read -r path; do
                is_readable_file "$path" || { log_entry "$section" "unreadable" "" "" "" "" "$path" ""; continue; }
                
                if [[ "$top_level_dir" == true ]]; then
                    [[ -n "${DIR_SEEN[$path]:-}" ]] && continue  # Already seen
                    [[ -d "$path" ]] && continue                 # Skip subdirectories
                    [[ "$action" == "ignore" ]] && continue
                fi

                size=$(safe_stat_size "$path" || echo 0)
                mtime=$(safe_stat_mtime "$path" || echo 0)
                age=$((now - mtime))

                # Determine exclusion/inclusion criteria
                criteria_failed=""; excluded_reason="";dest_path=""

                # file extension filters
                # Extension whitelist filter
                if [[ -n "$ext_whitelist" ]]; then
                    [[ "$path" =~ $ext_whitelist ]] || excluded_reason+="NotOnExtWL|"; fi
                if [[ -n "$ext_blacklist" ]]; then
                    [[ "$path" =~ $ext_blacklist ]] && excluded_reason+="OnExtBL|"; fi
                if [[ -n "regex_blacklist" ]]; then
                    [[ "$path" =~ $regex_blacklist ]] && excluded_reason+="OnRgxBL|"; fi

                # Apply size and age filters if applicable
                [[ -n "$max_age" ]] && (( age > max_age * 86400 )) && excluded_reason+="age>${max_age}d|"
                [[ -n "$min_age" ]] && (( age < min_age * 86400 )) && excluded_reason+="age<${min_age}d|"
                [[ -n "$max_size" ]] && (( size > max_size )) && excluded_reason+="size>${max_size}B|"
                [[ -n "$min_size" ]] && (( size < min_size )) && excluded_reason+="size<${min_size}B|"

                criteria_met=$([[ -z $excluded_reason ]] && echo "true" || echo "false" )

                if [[ "$criteria_met" == true ]]; then
                    DIR_SEEN["$path"]=1
                    [[ $DEBUG_LEVEL -ge 3 ]] && echo "$section adding $path to seen files: ${#DIR_SEEN[@]}"
                fi;

                # Handle action
                handle_path_action "$section" "$action" "$path" "$criteria_failed" "$excluded_reason" "$criteria_met"
            done           
        fi
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "dir $dir_path seen files: ${#DIR_SEEN[@]}"
    done    
    [[ $DEBUG_LEVEL -ge 3 ]] && echo "section $section seen files: ${#DIR_SEEN[@]}"
done < <(jq -r '.section | keys[]' "$CONFIG_FILE")

[[ $DEBUG_LEVEL -ge 3 ]] && echo "before unmatched seen files: ${#DIR_SEEN[@]}"

# --- Handle unmatched top-level dirs if configured ---
if jq -e '.unmatched_dirs' "$CONFIG_FILE" > /dev/null; then
  unmatched_action=$(jq -r '.unmatched_dirs.action // "log"' "$CONFIG_FILE")

  #readarray -t all_top_dirs < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d)
  [[ $DEBUG_LEVEL -ge 3 ]] && echo "start of unmatched seen files: ${#DIR_SEEN[@]}"

  for dir_path in "${candidate_dirs[@]}"; do
    if [[ -n "${DIR_SEEN[$dir_path]:-}" ]]; then 
        [[ $DEBUG_LEVEL -ge 3 ]] && echo "unmatched: $dir_path already seen"
        continue
    fi

    handle_path_action "unmatched_dirs" "$unmatched_action" "$dir_path"

  done
fi
