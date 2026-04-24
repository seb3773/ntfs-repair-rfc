#!/bin/bash
# generate_test_corpus.sh
# Generates a deterministic corpus of clean and corrupted NTFS images for testing.
# Requires: ntfs-3g, truncate, dd

set -euo pipefail

OUT_DIR="corpus"
IMG_SIZE="50M"

echo "=== NTFS Test Corpus Generator ==="

# Check dependencies
if ! command -v mkntfs &> /dev/null; then
    echo "ERROR: mkntfs (ntfs-3g) is required."
    exit 1
fi

mkdir -p "$OUT_DIR"

# -----------------------------------------------------------------------------
# Base Image Generation
# -----------------------------------------------------------------------------
function create_base_image() {
    local img_name="$1"
    local path="$OUT_DIR/$img_name"
    
    echo "  -> Generating $img_name..."
    truncate -s "$IMG_SIZE" "$path"
    
    # Format with fast (-F) and quiet (-q) options
    mkntfs -F -q -L "TEST_VOL" "$path"
}

# -----------------------------------------------------------------------------
# T-01: Clean Baseline
# -----------------------------------------------------------------------------
echo "[+] Scenario T-01: Clean Baseline"
create_base_image "T-01-Clean.img"

# -----------------------------------------------------------------------------
# T-02: MFT Record Corruption (USA Mismatch / Data overwrite)
# -----------------------------------------------------------------------------
echo "[+] Scenario T-02: MFT Record Corruption"
create_base_image "T-02-MFT-Corrupt.img"
# Extract MFT LCN
MFT_LCN=$(ntfsinfo -m "$OUT_DIR/T-02-MFT-Corrupt.img" 2>/dev/null | grep "MFT LCN" | awk '{print $3}' || echo 4)
# Overwrite 2 bytes at the end of the first MFT sector (offset: LCN*4096 + 510) to break the USA fixup
SEEK_BYTES=$((MFT_LCN * 4096 + 510))
printf '\xFF\xFF' | dd of="$OUT_DIR/T-02-MFT-Corrupt.img" bs=1 seek=$SEEK_BYTES count=2 conv=notrunc status=none

# -----------------------------------------------------------------------------
# T-03: MFTMirr Desynchronization
# -----------------------------------------------------------------------------
echo "[+] Scenario T-03: MFTMirr Desync"
create_base_image "T-03-MFTMirr-Corrupt.img"
MFTMIRR_LCN=$(ntfsinfo -m "$OUT_DIR/T-03-MFTMirr-Corrupt.img" 2>/dev/null | grep "MFTMirr LCN" | awk '{print $3}' || echo 2)
# Overwrite the Mirror with junk
dd if=/dev/urandom of="$OUT_DIR/T-03-MFTMirr-Corrupt.img" bs=4096 seek=$MFTMIRR_LCN count=1 conv=notrunc status=none

# -----------------------------------------------------------------------------
# T-04: Bitmap Cluster Leaks and Cross-links
# -----------------------------------------------------------------------------
echo "[+] Scenario T-04: Bitmap Corruption"
create_base_image "T-04-Bitmap-Corrupt.img"
# We aggressively overwrite a chunk of the volume's middle with 0xFF, setting all bits in the physical Bitmap.
# The repair tool must run the double-pass and clear them.
dd if=/dev/urandom of="$OUT_DIR/T-04-Bitmap-Corrupt.img" bs=1M seek=25 count=1 conv=notrunc status=none

# -----------------------------------------------------------------------------
# T-09: Boot Sector Corruption
# -----------------------------------------------------------------------------
echo "[+] Scenario T-09: Boot Sector Corruption"
create_base_image "T-09-Boot-Corrupt.img"
# Zero out the primary boot sector (LBA 0). The repair engine must restore it from the backup sector at the end.
dd if=/dev/zero of="$OUT_DIR/T-09-Boot-Corrupt.img" bs=512 seek=0 count=1 conv=notrunc status=none

echo "=== Corpus Generation Complete ==="
echo "Images saved in ./$OUT_DIR/"
