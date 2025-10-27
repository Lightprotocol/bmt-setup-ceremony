#!/usr/bin/env bash
set -euo pipefail

# Extract pk/vk from ceremony ph2 files
# Usage: ./extract-keys.sh <contribution_id>

CONTRIB_ID="${1:-0010_samkim}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRIBUTIONS_DIR="$SCRIPT_DIR/../contributions"
KEYS_DIR="$SCRIPT_DIR/../ceremony-keys"
SETUP_BIN="$SCRIPT_DIR/../semaphore-mtb-setup/semaphore-mtb-setup"

[[ ! -f "$SETUP_BIN" ]] && echo "Error: semaphore-mtb-setup binary not found" && exit 1
[[ ! -d "$CONTRIBUTIONS_DIR/$CONTRIB_ID" ]] && echo "Error: $CONTRIB_ID not found" && exit 1

mkdir -p "$KEYS_DIR/batch"
mkdir -p "$KEYS_DIR/v1"
mkdir -p "$KEYS_DIR/v2"

echo "========================================"
echo "Extracting Ceremony Keys"
echo "========================================"
echo "Contribution: $CONTRIB_ID"
echo ""

total=0
success=0

for ph2 in "$CONTRIBUTIONS_DIR/$CONTRIB_ID"/*/*.ph2; do
    [[ ! -f "$ph2" ]] && continue
    
    base=$(basename "$ph2" .ph2)
    # Remove contributor suffix
    circuit_name=$(echo "$base" | sed -E 's/_[^_]+_contribution_[0-9]+$//')
    
    # Determine version directory
    if [[ "$ph2" == *"/batch/"* ]]; then
        version="batch"
    elif [[ "$ph2" == *"/v1/"* ]]; then
        version="v1"
    elif [[ "$ph2" == *"/v2/"* ]]; then
        version="v2"
    else
        echo "Skipping unknown version: $ph2"
        continue
    fi
    
    pk_out="$KEYS_DIR/$version/${circuit_name}.pk"
    vk_out="$KEYS_DIR/$version/${circuit_name}.vk"
    
    # Skip if already extracted
    if [[ -f "$pk_out" && -f "$vk_out" ]]; then
        echo "  $circuit_name ... (exists)"
        success=$((success + 1))
        total=$((total + 1))
        continue
    fi
    
    total=$((total + 1))
    echo -n "  $circuit_name ... "
    
    # Extract keys to temp directory
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    if "$SETUP_BIN" key "$ph2" >/dev/null 2>&1; then
        if [[ -f "pk" && -f "vk" ]]; then
            mv pk "$pk_out"
            mv vk "$vk_out"
            success=$((success + 1))
            echo "✓"
        else
            echo "✗ (no output)"
        fi
    else
        echo "✗ (extraction failed)"
    fi
    
    cd - >/dev/null
    rm -rf "$temp_dir"
done

echo ""
echo "========================================"
echo "Extraction Complete!"
echo "========================================"
echo "Successfully extracted: $success/$total keys"
echo ""
echo "Keys saved to: $KEYS_DIR/"
echo "  - batch/*.pk + *.vk"
echo "  - v1/*.pk + *.vk"
echo "  - v2/*.pk + *.vk"
echo ""

