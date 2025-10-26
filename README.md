# BMT trusted setup ceremony

### For Contributors

1. Receive `contribution_urls.json` from coordinator
2. Run:

```bash
cd contributor
./contribute.sh contribution_urls.json
```

3. When you're done, delete the files and wipe RAM — eg by shutting down machine and disconnecting from power.

#### Verify your contribution (recommended)

Steps:

```bash
git clone https://github.com/lightprotocol/bmt-setup-ceremony
cd bmt-setup-ceremony

# One command:
# This builds the verifier (if needed) and verifies your latest contribution using saved offline inputs
make_verifier() { test -x semaphore-mtb-setup/semaphore-mtb-setup || (cd semaphore-mtb-setup && go build -o semaphore-mtb-setup .); }
make_verifier && contributor/verify_local.sh

# Optional: compare per-circuit hashes against a published attestation file
# Example: if the coordinator published 0003_swen_hashes.txt
# contributor/verify_local.sh "" "" path/to/0003_swen_hashes.txt

# Compare your local hashes.txt with what the coordinator publishes
HASH_FILE=contributor/ceremony_contribution_*/output/contribution_hashes.txt
echo "Your SHA256: $(shasum -a 256 $HASH_FILE | awk '{print $1}')"
echo "Coordinator's SHA256: <paste here>"
```

If your presigned read-access URLs have expired, reach out via DM or on Discord.

**Publish your attestation (strongly recommended):**

```bash
# The contributor script saves your hashes to this file
HASH_FILE=contributor/ceremony_contribution_*/output/contribution_hashes.txt

# Option 1 (Recommended): Open a PR to this repo
mkdir -p attestations/<your_contribution_id>
cp $HASH_FILE attestations/<your_contribution_id>/
git add attestations/<your_contribution_id>/
git commit -m "Add attestation for <your_contribution_id>"
# Open PR to https://github.com/lightprotocol/bmt-setup-ceremony

# Option 2: Create a GitHub Gist and share the link

# Option 3: Publish the SHA256 hash publicly
shasum -a 256 $HASH_FILE
```

### For Coordinators

#### 1. Initial Setup

```bash
cd coordinator

# Set up service account for URL signing
./create_key.sh <bucket-name>

# Initialize ceremony (generates R1CS and initial contribution)
./init.sh
```

#### 2. Upload Initial Contribution

```bash
# Upload to Google Cloud Storage
./upload.sh
# Verify upload
gsutil ls gs://<bucket>/ceremony/contributions/0000_initial/ | head -5
```

#### 3. Manage Contributors

For each contributor in sequence:

```bash
# Generate presigned URLs for contributor (all versions)
./generate_urls.sh <bucket> alice 0000_initial all
# → Creates 0001_alice_urls.json

# Send JSON file to Alice securely
# Wait for Alice to complete contribution

# Verify the contribution
./verify.sh 0001_alice

# If verification passes, continue to next contributor
# Generate presigned URLs for next contributor (all versions)
./generate_urls.sh <bucket> bob 0001_alice all
# → Creates 0002_bob_urls.json
```

#### 4. Complete Ceremony

After the final contribution:

```bash
# Extract proving and verification keys and build .key files
# Usage:
#   ./finalize.sh [contribution_id] [version]
# Example:
#   ./finalize.sh 0003_swen v2
./finalize.sh XXXX_final_contributor

# Keys will be in ../proving-keys/
# Option to upload to GCS when prompted
```

#### 5. Publish Results

- Share final keys publicly
- Publish all contributions for transparency
- Create attestation document with contributor list

#### Coordinator Workflow

```
init.sh → upload → generate_urls.sh → [wait] → verify.sh → repeat → finalize.sh
```

## Files

```
coordinator/
├── init.sh           # Initialize ceremony from R1CS
├── generate_urls.sh  # Create presigned URLs for contributor
├── verify.sh         # Verify contributions
└── finalize.sh       # Extract pk/vk and build .key files

contributor/
└── contribute.sh     # Run contribution with URLs file
```

## Circuits

- **101 total circuits**

  - V1: 30 circuits (tree height 26)
  - V2: 68 circuits (tree heights 32/40)
    - 16 combined (inclusion 1-4, non-inclusion 1-4)
    - 20 inclusion (accounts 1-20)
    - 32 non-inclusion (accounts 1-32)
  - Batch: 3 circuits (batch operations)

- **PTAU sizes**
  - PTAU 19 for V1/V2 circuits
  - PTAU 24 for batch circuits

## Dependencies

**Coordinator:**

- `light-protocol/prover/server` (Go project) to build .key files
- `go` toolchain (for running light-prover import-setup)
- `gsutil` (Google Cloud SDK) for GCS operations (keep keys safe; never commit them)
- `jq` (required when using generate_urls.sh with VERSION=all)

**Contributor:**

- `jq` (auto-installed if missing)
- `go` (to build semaphore-mtb-setup)
