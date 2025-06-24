#!/bin/bash
set -euo pipefail

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/tmp_protect_config.json"
CONFIG_FILE="$DEFAULT_CONFIG"
DRY_RUN=false

# Parse command-line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
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

# Check if jq is available
if ! command -v jq >/dev/null; then
  echo "Error: 'jq' is required but not installed." >&2
  exit 1
fi

# Validate config file
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found at $CONFIG_FILE" >&2
  exit 1
fi

# Load global config
SOURCE_DIR=$(jq -r '.global.source_dir' "$CONFIG_FILE")
DEST_DIR=$(jq -r '.global.destination_dir' "$CONFIG_FILE")
UIDS=$(jq -r '.global.uids[]' "$CONFIG_FILE")

echo "Parsed global config:"
echo "  Source: $SOURCE_DIR"
echo "  Destination: $DEST_DIR"
echo "  UIDs: $UIDS"
echo "  Dry run: $DRY_RUN"
echo ""

# List all configured sections (by name)
echo "Configured sections:"
jq -r '.section | keys[]' "$CONFIG_FILE" | while read -r section; do
  desc=$(jq -r ".section[\"$section\"].description // \"(no description)\"" "$CONFIG_FILE")
  action=$(jq -r ".section[\"$section\"].action // \"log\"" "$CONFIG_FILE")
  echo "  [$section] action=$action  desc=$desc"
done
