#!/usr/bin/env bash
set -euo pipefail

# Finalize ceremony from already-extracted pk/vk files
# Skips extraction step, builds .key files directly from proving-keys/
#
# Usage:
#   ./finalize-from-vk.sh [version]
#
# Examples:
#   ./finalize-from-vk.sh           # Build all .key files
#   ./finalize-from-vk.sh v1        # Build only v1 .key files
#   ./finalize-from-vk.sh batch     # Build only batch .key files

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEREMONY_KEYS_DIR="$SCRIPT_DIR/../proving-keys"
OUTPUT_DIR="$SCRIPT_DIR/../light-protocol-keys"
LIGHT_PROVER_REL="../../light-protocol-2/prover/server"
if [[ -d "$SCRIPT_DIR/$LIGHT_PROVER_REL" ]]; then
    LIGHT_PROVER="$(cd "$SCRIPT_DIR/$LIGHT_PROVER_REL" && pwd)"
    PROVING_KEYS_DEST="$LIGHT_PROVER/proving-keys"
else
    LIGHT_PROVER=""
    PROVING_KEYS_DEST=""
fi
CEREMONY_EVALS_DIR="$SCRIPT_DIR/../contributor/evals"
INITIAL_DIR="$SCRIPT_DIR/../contributions/0000_initial"

# Parse arguments
VERSION="${1:-}"

# Validate version if provided
if [[ -n "$VERSION" ]] && [[ ! "$VERSION" =~ ^(v1|v2|batch)$ ]]; then
    echo "Error: Invalid version: $VERSION"
    echo "Valid versions: v1, v2, batch"
    exit 1
fi

[[ ! -d "$CEREMONY_KEYS_DIR" ]] && echo "Error: proving-keys directory not found" && exit 1
[[ ! -d "$LIGHT_PROVER" ]] && echo "Error: light-protocol prover not found at $LIGHT_PROVER" && exit 1
[[ ! -d "$CEREMONY_EVALS_DIR" ]] && echo "Error: evals directory not found at $CEREMONY_EVALS_DIR" && exit 1
[[ ! -d "$INITIAL_DIR" ]] && echo "Error: initial contribution (r1cs) not found at $INITIAL_DIR" && exit 1

if ! command -v go >/dev/null 2>&1; then
    echo "Error: go toolchain not found. Please install Go (for key building)." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "========================================="
echo "Building .key Files from Ceremony Keys"
echo "========================================="
if [[ -n "$VERSION" ]]; then
    echo "Version: $VERSION"
fi
echo ""

# Step 1: Build .key files
echo "Step 1: Building .key files..."
echo ""

cd "$LIGHT_PROVER"

# Ensure evals are accessible from prover directory
if [[ -d "$CEREMONY_EVALS_DIR" ]]; then
    if [[ ! -e "evals" ]]; then
        echo "  Linking ceremony evals directory..."
        ln -sf "$CEREMONY_EVALS_DIR" evals
    fi
else
    echo "  Error: Ceremony evals directory not found at $CEREMONY_EVALS_DIR"
    exit 1
fi

total_keys=0
success_keys=0
failed_keys=0

# Process all pk/vk pairs (filtered by VERSION if specified)
for pk_file in "$CEREMONY_KEYS_DIR"/*.pk; do
    [[ ! -f "$pk_file" ]] && continue

    base=$(basename "$pk_file" .pk)

    # Filter by version if VERSION is specified
    if [[ -n "$VERSION" ]]; then
        if [[ "$VERSION" == "v1" ]] && [[ ! "$base" =~ ^v1_ ]]; then
            continue
        elif [[ "$VERSION" == "v2" ]] && [[ ! "$base" =~ ^v2_ ]]; then
            continue
        elif [[ "$VERSION" == "batch" ]] && [[ ! "$base" =~ ^(batch_|v2_(append|update|address-append)) ]]; then
            continue
        fi
    fi

    vk_file="$CEREMONY_KEYS_DIR/${base}.vk"

    [[ ! -f "$vk_file" ]] && echo "  Skipping $base (no vk file)" && continue

    total_keys=$((total_keys + 1))

    # Determine output filename based on naming convention
    # Try to match with existing R1CS file
    r1cs_candidates=()

    # Check 0000_initial
    r1cs_candidates+=(
        "$INITIAL_DIR/v1/r1cs/${base}.r1cs"
        "$INITIAL_DIR/v2/r1cs/${base}.r1cs"
        "$INITIAL_DIR/batch/r1cs/${base}.r1cs"
    )

    # Handle naming patterns (extracted keys don't have version prefix but r1cs files do)
    if [[ ! "$base" =~ ^v[12]_ ]] && [[ ! "$base" =~ ^batch_ ]]; then
        # Determine which version based on circuit naming
        if [[ "$base" == "address-append_40_250" ]] || [[ "$base" =~ ^(append|update)_32_500$ ]]; then
            # Batch circuits (append_32_500, update_32_500, address-append_40_250)
            r1cs_candidates+=(
                "$INITIAL_DIR/batch/r1cs/batch_${base}.r1cs"
            )
        elif [[ "$base" =~ ^combined_32_40 ]] || [[ "$base" =~ ^inclusion_32_ ]] || [[ "$base" =~ ^non-inclusion_40_ ]]; then
            # V2 circuits (32/40 tree heights)
            r1cs_candidates+=(
                "$INITIAL_DIR/v2/r1cs/v2_${base}.r1cs"
            )
        elif [[ "$base" =~ ^combined_26 ]] || [[ "$base" =~ ^inclusion_26_ ]] || [[ "$base" =~ ^non-inclusion_26_ ]]; then
            # V1 circuits (26 tree height)
            r1cs_candidates+=(
                "$INITIAL_DIR/v1/r1cs/v1_${base}.r1cs"
            )
        fi
    fi

    r1cs_file=""
    output_base=""

    for candidate in "${r1cs_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            r1cs_file="$candidate"
            output_base=$(basename "$candidate" .r1cs)
            break
        fi
    done

    if [[ -z "$r1cs_file" ]]; then
        # Debug: show first candidate for troubleshooting
        if [[ ${#r1cs_candidates[@]} -gt 0 ]]; then
            echo "  $base: Ceremony R1CS not found (tried: ${r1cs_candidates[0]})"
        else
            echo "  $base: Ceremony R1CS not found (no candidates)"
        fi
        failed_keys=$((failed_keys + 1))
        continue
    fi

    output_file="$OUTPUT_DIR/${output_base}.key"
    vkey_output="$OUTPUT_DIR/${output_base}.vkey"

    echo -n "  $output_base ... "

    # Determine circuit type and parameters from filename
    # Remove version prefix for parsing
    circuit_name=$(echo "$base" | sed 's/^v[12]_//')

    # Detect if this is a V1 circuit (needs --v1 flag)
    # Check r1cs filename, not extracted key name, since extracted keys don't have v1_ prefix
    is_v1=false
    if [[ "$r1cs_file" =~ v1_ ]]; then
        is_v1=true
    fi

    if [[ $circuit_name =~ ^combined_([0-9]+)_([0-9]+)_([0-9]+)_([0-9]+)$ ]]; then
        # V2 Combined circuit: combined_<inc-height>_<non-inc-height>_<inc-accounts>_<non-inc-accounts>
        inc_height="${BASH_REMATCH[1]}"
        non_inc_height="${BASH_REMATCH[2]}"
        inc_accounts="${BASH_REMATCH[3]}"
        non_inc_accounts="${BASH_REMATCH[4]}"
        circuit_args="--circuit combined --r1cs $r1cs_file"
        circuit_args="$circuit_args --inclusion-tree-height $inc_height --inclusion-compressed-accounts $inc_accounts"
        circuit_args="$circuit_args --non-inclusion-tree-height $non_inc_height --non-inclusion-compressed-accounts $non_inc_accounts"
    elif [[ $circuit_name =~ ^combined_([0-9]+)_([0-9]+)_([0-9]+)$ ]]; then
        # V1 Combined circuit: combined_<height>_<inc-accounts>_<non-inc-accounts>
        height="${BASH_REMATCH[1]}"
        inc_accounts="${BASH_REMATCH[2]}"
        non_inc_accounts="${BASH_REMATCH[3]}"

        # Override output_base to use 4-number format and preserve version prefix from r1cs file
        # Extract version prefix from r1cs filename, not from extracted key name
        version_prefix=""
        if [[ "$r1cs_file" =~ v1_ ]]; then
            version_prefix="v1_"
        elif [[ "$r1cs_file" =~ v2_ ]]; then
            version_prefix="v2_"
        fi
        output_base="${version_prefix}combined_${height}_${height}_${inc_accounts}_${non_inc_accounts}"
        output_file="$OUTPUT_DIR/${output_base}.key"
        vkey_output="$OUTPUT_DIR/${output_base}.vkey"

        circuit_args="--circuit combined --r1cs $r1cs_file"
        circuit_args="$circuit_args --inclusion-tree-height $height --inclusion-compressed-accounts $inc_accounts"
        circuit_args="$circuit_args --non-inclusion-tree-height $height --non-inclusion-compressed-accounts $non_inc_accounts"
    elif [[ $circuit_name =~ ^inclusion_([0-9]+)_([0-9]+)$ ]]; then
        # Inclusion circuit: inclusion_<height>_<accounts>
        height="${BASH_REMATCH[1]}"
        accounts="${BASH_REMATCH[2]}"
        circuit_args="--circuit inclusion --r1cs $r1cs_file"
        circuit_args="$circuit_args --inclusion-tree-height $height --inclusion-compressed-accounts $accounts"
    elif [[ $circuit_name =~ ^non-inclusion_([0-9]+)_([0-9]+)$ ]]; then
        # Non-inclusion circuit: non-inclusion_<height>_<accounts>
        height="${BASH_REMATCH[1]}"
        accounts="${BASH_REMATCH[2]}"
        circuit_args="--circuit non-inclusion --r1cs $r1cs_file"
        circuit_args="$circuit_args --non-inclusion-tree-height $height --non-inclusion-compressed-accounts $accounts"
    elif [[ $circuit_name =~ ^(batch_)?append_([0-9]+)_([0-9]+)$ ]]; then
        # Batch append circuit: append_<height>_<batch-size>
        height="${BASH_REMATCH[2]}"
        batch_size="${BASH_REMATCH[3]}"
        circuit_args="--circuit append --r1cs $r1cs_file"
        circuit_args="$circuit_args --append-tree-height $height --append-batch-size $batch_size"
    elif [[ $circuit_name =~ ^(batch_)?update_([0-9]+)_([0-9]+)$ ]]; then
        # Batch update circuit: update_<height>_<batch-size>
        height="${BASH_REMATCH[2]}"
        batch_size="${BASH_REMATCH[3]}"
        circuit_args="--circuit update --r1cs $r1cs_file"
        circuit_args="$circuit_args --update-tree-height $height --update-batch-size $batch_size"
    elif [[ $circuit_name =~ ^(batch_)?address-append_([0-9]+)_([0-9]+)$ ]]; then
        # Batch address-append circuit: address-append_<height>_<batch-size>
        height="${BASH_REMATCH[2]}"
        batch_size="${BASH_REMATCH[3]}"
        circuit_args="--circuit address-append --r1cs $r1cs_file"
        circuit_args="$circuit_args --address-append-tree-height $height --address-append-batch-size $batch_size"
    else
        echo "(unknown circuit type: $circuit_name)"
        failed_keys=$((failed_keys + 1))
        continue
    fi

    # Add --v1 flag for V1 circuits
    if [[ "$is_v1" == "true" ]]; then
        circuit_args="$circuit_args --v1"
    fi

    set +e
    output=$(go run main.go import-setup \
        $circuit_args \
        --pk "$pk_file" \
        --vk "$vk_file" \
        --output "$output_file" \
        --vkey-output "$vkey_output" 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q "Proving system written"; then
        success_keys=$((success_keys + 1))
        echo "✓"
    else
        failed_keys=$((failed_keys + 1))
        echo "✗"
        if [[ -n "$output" ]]; then
            echo "     Error: $output" | head -1
        fi
    fi
done

echo ""
echo "Key Building: $success_keys/$total_keys successful, $failed_keys failed"
echo ""

# Step 2: Copy to prover
echo "Step 2: Copying keys to prover..."
echo ""

copied_keys=0
copied_vkeys=0

# Copy .key files
for key_file in "$OUTPUT_DIR"/*.key; do
    [[ ! -f "$key_file" ]] && continue

    base=$(basename "$key_file")
    dest_file="$PROVING_KEYS_DEST/${base}"

    echo -n "  $base ... "
    cp "$key_file" "$dest_file"
    copied_keys=$((copied_keys + 1))
    echo "✓"
done

# Copy .vkey files
for vkey_file in "$OUTPUT_DIR"/*.vkey; do
    [[ ! -f "$vkey_file" ]] && continue

    base=$(basename "$vkey_file")
    dest_file="$PROVING_KEYS_DEST/${base}"

    cp "$vkey_file" "$dest_file"
    copied_vkeys=$((copied_vkeys + 1))
done

# Update CHECKSUM file
echo ""
echo "Updating CHECKSUM file..."
if [[ -n "$PROVING_KEYS_DEST" ]] && [[ -d "$PROVING_KEYS_DEST" ]]; then
    cd "$PROVING_KEYS_DEST"
    # Generate checksums for all .key and .vkey files
    shasum -a 256 *.key *.vkey 2>/dev/null | sort -k2 > CHECKSUM.new
    mv CHECKSUM.new CHECKSUM
    echo "  ✓ CHECKSUM updated with $(wc -l < CHECKSUM | tr -d ' ') entries"
fi

echo ""
echo "========================================="
echo "Finalization Complete!"
echo "========================================="
echo "Built .key files: $success_keys/$total_keys"
echo "Failed: $failed_keys"
echo "Copied to prover: $copied_keys keys, $copied_vkeys vkeys"
echo ""
echo "Ceremony keys deployed to: $PROVING_KEYS_DEST"
echo ""
echo "Next step:"
echo "  cd $LIGHT_PROVER"
echo "  go test -v -run TestFull"
echo ""

