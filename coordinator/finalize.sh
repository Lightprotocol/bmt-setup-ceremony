#!/usr/bin/env bash
set -euo pipefail

# Finalize trusted setup ceremony
# Extracts keys from final contribution, builds .key files, and copies to prover
#
# Usage:
#   ./finalize.sh [contribution_id] [version]
#
# Examples:
#   ./finalize.sh 0001_sergey v1              # Finalize sergey's v1 contribution
#   ./finalize.sh 0001_sergey v2              # Finalize sergey's v2 contribution
#   ./finalize.sh 0001_sergey                 # Finalize all versions
#   ./finalize.sh                             # Auto-detect latest contribution

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRIBUTIONS_DIR="$(cd "$SCRIPT_DIR/../contributions" && pwd)"
CEREMONY_KEYS_DIR="$(cd "$SCRIPT_DIR/../proving-keys" && pwd)"
CEREMONY_R1CS_DIR="$SCRIPT_DIR/../ceremony/r1cs"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/../light-protocol-keys" && pwd)"
LIGHT_PROVER_REL="../../light-protocol/prover/server"
if [[ -d "$SCRIPT_DIR/$LIGHT_PROVER_REL" ]]; then
    LIGHT_PROVER="$(cd "$SCRIPT_DIR/$LIGHT_PROVER_REL" && pwd)"
    PROVING_KEYS_DEST="$LIGHT_PROVER/proving-keys"
else
    LIGHT_PROVER=""
    PROVING_KEYS_DEST=""
fi
SETUP_BIN="$SCRIPT_DIR/../semaphore-mtb-setup/semaphore-mtb-setup"
CEREMONY_EVALS_DIR="$(cd "$SCRIPT_DIR/../contributor/evals" && pwd)"

# Parse arguments
CONTRIB_ID="${1:-}"
VERSION="${2:-}"

# Dependency checks for downloads (only if not using local files)
if [[ -n "$CONTRIB_ID" ]] && [[ ! -d "$SCRIPT_DIR/../contributions/$CONTRIB_ID" ]]; then
    if ! command -v gsutil >/dev/null 2>&1; then
        echo "Error: gsutil not found. Please install Google Cloud SDK for downloading contributions." >&2
        exit 1
    fi
fi

# Check if using local data directory (for testing)
if [[ -d "$SCRIPT_DIR/../data" ]] && [[ "$CONTRIB_ID" != --* ]]; then
    # If data directory exists and we're not using flags, use it as contributions dir
    if [[ -n "$CONTRIB_ID" ]] && [[ -d "$SCRIPT_DIR/../data/$CONTRIB_ID" ]]; then
        echo "Using local data directory for testing"
        CONTRIBUTIONS_DIR="$(cd "$SCRIPT_DIR/../data" && pwd)"
    elif [[ -z "$CONTRIB_ID" ]]; then
        # Auto-detect: prefer data dir if it has contributions
        data_contribs=$(ls -d "$SCRIPT_DIR/../data"/*/ 2>/dev/null | wc -l)
        if [[ $data_contribs -gt 0 ]]; then
            echo "Using local data directory for testing"
            CONTRIBUTIONS_DIR="$(cd "$SCRIPT_DIR/../data" && pwd)"
        fi
    fi
fi

# Validate version if provided
if [[ -n "$VERSION" ]] && [[ ! "$VERSION" =~ ^(v1|v2|batch)$ ]]; then
    echo "Error: Invalid version: $VERSION"
    echo "Valid versions: v1, v2, batch"
    exit 1
fi

[[ ! -f "$SETUP_BIN" ]] && echo "Error: semaphore-mtb-setup binary not found" && exit 1
[[ ! -d "$LIGHT_PROVER" ]] && echo "Error: light-protocol prover not found at $LIGHT_PROVER" && exit 1
if ! command -v go >/dev/null 2>&1; then
    echo "Error: go toolchain not found. Please install Go (for key building)." >&2
    exit 1
fi

mkdir -p "$CEREMONY_KEYS_DIR"
mkdir -p "$OUTPUT_DIR"

echo "========================================="
echo "Finalizing Ceremony"
echo "========================================="
if [[ -n "$VERSION" ]]; then
    echo "Version: $VERSION"
fi
echo ""

# Step 1: Find contribution files
echo "Step 1: Finding contribution files..."

if [[ -n "$CONTRIB_ID" ]]; then
    # Check if files exist locally first
    if [[ -d "$CONTRIBUTIONS_DIR/$CONTRIB_ID" ]]; then
        echo "  Using local files: $CONTRIB_ID"
    else
        # Download contribution from GCS
        echo "  Downloading contribution: $CONTRIB_ID"

        BUCKET="${BUCKET:-light-protocol-proving-keys}"

        # Determine which versions to download
        if [[ -n "$VERSION" ]]; then
            # Download specific version
            VERSIONS=("$VERSION")
        else
            # Download all versions
            VERSIONS=("v1" "v2" "batch")
        fi

        # Download each version
        for ver in "${VERSIONS[@]}"; do
            mkdir -p "$CONTRIBUTIONS_DIR/$CONTRIB_ID/$ver"
            mkdir -p "$CONTRIBUTIONS_DIR/$CONTRIB_ID/$ver/r1cs"

            echo "  Downloading $ver files..."
            gsutil -m cp "gs://$BUCKET/ceremony/contributions/$CONTRIB_ID/$ver"/*.ph2 \
                         "gs://$BUCKET/ceremony/contributions/$CONTRIB_ID/$ver"/*.evals \
                         "$CONTRIBUTIONS_DIR/$CONTRIB_ID/$ver/" 2>/dev/null || true

            # Also download R1CS files if they exist
            echo "  Downloading $ver R1CS files..."
            gsutil -m cp "gs://$BUCKET/ceremony/contributions/$CONTRIB_ID/$ver/r1cs"/*.r1cs \
                         "$CONTRIBUTIONS_DIR/$CONTRIB_ID/$ver/r1cs/" 2>/dev/null || true
        done
    fi

    if [[ -n "$VERSION" ]]; then
        CONTRIB_PATTERN="$CONTRIBUTIONS_DIR/$CONTRIB_ID/$VERSION/*.ph2"
    else
        CONTRIB_PATTERN="$CONTRIBUTIONS_DIR/$CONTRIB_ID/*/*.ph2"
    fi
else
    # Auto-detect latest contribution - check local first, then GCS
    CONTRIB_PATTERN="$CONTRIBUTIONS_DIR/*.ph2"

    shopt -s nullglob
    contrib_files=()
    for f in $CONTRIB_PATTERN; do
        [[ -f "$f" ]] && contrib_files+=("$f")
    done
    shopt -u nullglob

    # If no local files found, try to download from GCS
    if [[ ${#contrib_files[@]} -eq 0 ]] && command -v gsutil &> /dev/null; then
        echo "  No local contribution files found, checking GCS..."

        # Find latest contribution directory on GCS
        BUCKET="${BUCKET:-light-protocol-proving-keys}"
        latest_contrib=$(gsutil ls "gs://$BUCKET/ceremony/contributions/" | grep -E "/[0-9]{4}_[^/]+/$" | sort | tail -1)

        if [[ -n "$latest_contrib" ]]; then
            contrib_id=$(basename "${latest_contrib%/}")
            echo "  Found contribution on GCS: $contrib_id"
            echo "  Downloading..."

            mkdir -p "$CONTRIBUTIONS_DIR/$contrib_id"
            gsutil -m cp "${latest_contrib}"*.ph2 "${latest_contrib}"*.evals "$CONTRIBUTIONS_DIR/$contrib_id/" 2>/dev/null || true

            CONTRIB_PATTERN="$CONTRIBUTIONS_DIR/$contrib_id/*.ph2"
        fi
    fi
fi

shopt -s nullglob
contrib_files=()
for f in $CONTRIB_PATTERN; do
    [[ -f "$f" ]] && contrib_files+=("$f")
done
shopt -u nullglob

if [[ ${#contrib_files[@]} -eq 0 ]]; then
    echo "Error: No contribution files found"
    echo "Pattern: $CONTRIB_PATTERN"
    exit 1
fi

echo "  Found ${#contrib_files[@]} contribution files"
echo ""

# Step 2: Extract pk/vk from contributions
echo "Step 2: Extracting proving/verifying keys..."
echo ""

cd "$CEREMONY_KEYS_DIR"
total_extracted=0
success_extracted=0

for contrib_file in "${contrib_files[@]}"; do
    base=$(basename "$contrib_file" .ph2)
    # Remove contribution suffix: _contributor_contribution_NNNN
    # e.g., v1_combined_26_1_1_sergey_contribution_0001 -> v1_combined_26_1_1
    #       v1_combined_26_1_1_0000 -> v1_combined_26_1_1
    circuit_name=$(echo "$base" | sed -E 's/_(([^_]+_contribution_[0-9]+)|([0-9]{4}))$//')

    # Check if already extracted
    if [[ -f "${circuit_name}.pk" && -f "${circuit_name}.vk" ]]; then
        echo "  $circuit_name ... (exists)"
        success_extracted=$((success_extracted + 1))
        total_extracted=$((total_extracted + 1))
        continue
    fi

    total_extracted=$((total_extracted + 1))
    echo -n "  $circuit_name ... "

    # Extract keys
    if "$SETUP_BIN" key "$contrib_file" >/dev/null 2>&1; then
        # Rename to circuit name
        [[ -f "pk" ]] && mv pk "${circuit_name}.pk"
        [[ -f "vk" ]] && mv vk "${circuit_name}.vk"

        if [[ -f "${circuit_name}.pk" && -f "${circuit_name}.vk" ]]; then
            success_extracted=$((success_extracted + 1))
        else
            echo " (missing output)"
        fi
    fi
done

echo ""
echo "Key Extraction: $success_extracted/$total_extracted successful"
echo ""

# Step 3: Build .key files
echo "Step 3: Building .key files..."
echo ""

cd "$LIGHT_PROVER"

# Ensure evals are accessible from prover directory
if [[ -d "$CEREMONY_EVALS_DIR" ]]; then
    if [[ ! -e "evals" ]]; then
        echo "  Linking ceremony evals directory..."
        ln -s "$CEREMONY_EVALS_DIR" evals
    fi
else
    echo "  Warning: Ceremony evals directory not found at $CEREMONY_EVALS_DIR"
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
    # Check contribution's own r1cs directory first, then 0000_initial, then ceremony/r1cs
    r1cs_candidates=()

    # If CONTRIB_ID is set, check its r1cs directories first
    if [[ -n "$CONTRIB_ID" ]]; then
        r1cs_candidates+=(
            "$CONTRIBUTIONS_DIR/$CONTRIB_ID/v1/r1cs/${base}.r1cs"
            "$CONTRIBUTIONS_DIR/$CONTRIB_ID/v2/r1cs/${base}.r1cs"
            "$CONTRIBUTIONS_DIR/$CONTRIB_ID/batch/r1cs/${base}.r1cs"
        )
    fi

    # Then check 0000_initial (always in contributions dir, not data dir)
    INITIAL_DIR="$SCRIPT_DIR/../contributions/0000_initial"
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

    # Finally fall back to ceremony/r1cs
    r1cs_candidates+=("$CEREMONY_R1CS_DIR/${base}.r1cs")

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

    # Add --v1 flag for V1 circuits (and omit R1CS - it will be regenerated)
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
    set -e

    if echo "$output" | grep -q "Proving system written"; then
        success_keys=$((success_keys + 1))
    else
        failed_keys=$((failed_keys + 1))
    fi
done

echo ""
echo "Key Building: $success_keys/$total_keys successful, $failed_keys failed"
echo ""

# Step 4: Copy to prover
echo "Step 4: Copying keys to prover..."
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
echo "Extracted pk/vk: $success_extracted/$total_extracted"
echo "Built .key files: $success_keys/$total_keys"
echo "Copied to prover: $copied_keys keys, $copied_vkeys vkeys"
echo ""
echo "Ceremony keys deployed to: $PROVING_KEYS_DEST"
echo ""
echo "Next step:"
echo "  cd $LIGHT_PROVER"
echo "  go test -v -run TestFull"
echo ""
