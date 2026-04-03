#!/bin/bash
# Build a patched Ubuntu HWE kernel with the CVM guard (BadAML mitigation).
#
# This script:
#   1. Downloads the Ubuntu HWE kernel source (matching linux-image-generic-hwe-24.04)
#   2. Applies the CVM guard patch (blocks AML access to CVM private memory)
#   3. Builds a .deb kernel package
#   4. Outputs it to the specified directory
#
# The resulting .deb is a drop-in replacement for linux-image-generic-hwe-24.04
# with a single change: the ACPI memory space handler denies AML bytecode from
# reading or writing pages marked as encrypted/private on TDX and SEV-SNP VMs.
#
# Requirements:
#   - Ubuntu 24.04 (Noble) build environment
#   - ~20 GB disk, ~30 min build time on 4 cores
#   - Must run as root (or with fakeroot)
#
# Usage:
#   sudo ./build-kernel.sh [--output-dir /path/to/debs]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
OUTPUT_DIR="${1:-$SCRIPT_DIR/debs}"
BUILD_DIR="/tmp/privasys-kernel-build"

# How many parallel jobs for the kernel build.
JOBS="$(nproc)"

echo "=== Privasys Kernel Builder ==="
echo "Patch dir:  $PATCH_DIR"
echo "Output dir: $OUTPUT_DIR"
echo "Build dir:  $BUILD_DIR"
echo "Jobs:       $JOBS"

# ── Step 0: Prerequisites ──
echo ""
echo "=== Step 0: Installing build dependencies ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential fakeroot dpkg-dev \
    libncurses-dev flex bison libssl-dev libelf-dev \
    bc dwarves debhelper rsync cpio kmod \
    python3 python3-dev apt-src 2>/dev/null || true

# ── Step 1: Identify and fetch kernel source ──
echo ""
echo "=== Step 1: Fetching kernel source ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Find which kernel version linux-image-generic-hwe-24.04 resolves to.
KERNEL_PKG=$(apt-cache depends linux-image-generic-hwe-24.04 2>/dev/null \
    | grep -oP 'linux-image-\d[\d.]+\d-\d+-generic' | head -1)
if [ -z "$KERNEL_PKG" ]; then
    echo "ERROR: Cannot resolve linux-image-generic-hwe-24.04 to a concrete package"
    exit 1
fi
echo "Resolved to: $KERNEL_PKG"

# Extract version components: e.g. "6.19.0-20-generic" -> source "linux-hwe-6.19"
KVER=$(echo "$KERNEL_PKG" | grep -oP '\d+\.\d+\.\d+-\d+')
KMAJMIN=$(echo "$KVER" | grep -oP '^\d+\.\d+')
echo "Kernel version: $KVER  (major.minor: $KMAJMIN)"

# Get the source package.
SRC_PKG="linux-hwe-${KMAJMIN}"
echo "Source package: $SRC_PKG"

# Enable source repositories if needed.
if ! apt-get source --download-only "$SRC_PKG" 2>/dev/null; then
    echo "Enabling deb-src repositories..."
    sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list.d/*.list 2>/dev/null || true
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    apt-get update -qq
fi

apt-get source "$SRC_PKG"
apt-get build-dep -y "$SRC_PKG"

# Find the extracted source directory.
SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "linux-hwe-*" | head -1)
if [ -z "$SRC_DIR" ]; then
    SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "linux-*" | head -1)
fi
if [ -z "$SRC_DIR" ]; then
    echo "ERROR: kernel source directory not found in $BUILD_DIR"
    exit 1
fi
echo "Source dir: $SRC_DIR"
cd "$SRC_DIR"

# ── Step 2: Apply CVM guard patch ──
echo ""
echo "=== Step 2: Applying CVM guard patch ==="
PATCH_FILE="$PATCH_DIR/0001-acpi-deny-aml-access-to-cvm-private-memory.patch"
if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Patch not found: $PATCH_FILE"
    exit 1
fi

# The patch was written against upstream. We need to apply it to the Ubuntu tree
# which may have slightly different paths or context. Try git apply first, then
# fall back to manual application.
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    echo "Patch applied via git apply"
elif patch -p1 --dry-run < "$PATCH_FILE" 2>/dev/null; then
    patch -p1 < "$PATCH_FILE"
    echo "Patch applied via patch -p1"
else
    echo "Automatic patch application failed. Applying manually..."
    # The patch is small: one #include and one guard call in exregion.c,
    # plus a new header file. Apply by hand.
    EXREGION="drivers/acpi/acpica/exregion.c"
    GUARD_H="drivers/acpi/acpica/cvm_guard.h"

    if [ ! -f "$EXREGION" ]; then
        echo "ERROR: $EXREGION not found in source tree"
        exit 1
    fi

    # Extract cvm_guard.h from the patch (everything between +++ b/.../cvm_guard.h and the end).
    sed -n '/^diff --git.*cvm_guard\.h/,/^-- $/p' "$PATCH_FILE" \
        | sed -n '/^+[^+]/p' | sed 's/^+//' > "$GUARD_H"

    if [ ! -s "$GUARD_H" ]; then
        echo "ERROR: Failed to extract cvm_guard.h from patch"
        exit 1
    fi
    echo "Created $GUARD_H ($(wc -l < "$GUARD_H") lines)"

    # Add #include "cvm_guard.h" after ACPI_MODULE_NAME line.
    sed -i '/^ACPI_MODULE_NAME("exregion")/a\\n#include "cvm_guard.h"' "$EXREGION"

    # Add the guard call: after the logical_addr_ptr assignment in the access: label.
    # Find "((u64) address - (u64) mm->physical_address);" and add the guard after it.
    sed -i '/((u64) address - (u64) mm->physical_address);/a\\n\tif (cvm_guard_deny_aml_access((unsigned long)logical_addr_ptr))\n\t\treturn_ACPI_STATUS(AE_AML_ILLEGAL_ADDRESS);' "$EXREGION"

    echo "Patched $EXREGION manually"
fi

# Verify the patch landed.
if ! grep -q "cvm_guard" drivers/acpi/acpica/exregion.c; then
    echo "ERROR: Patch verification failed - cvm_guard not found in exregion.c"
    exit 1
fi
if [ ! -f drivers/acpi/acpica/cvm_guard.h ]; then
    echo "ERROR: Patch verification failed - cvm_guard.h not found"
    exit 1
fi
echo "Patch verified OK"

# ── Step 3: Update version to distinguish from stock kernel ──
echo ""
echo "=== Step 3: Updating kernel version ==="
# Append +privasys to the local version so the package name is distinct.
if [ -f "debian.hwe-${KMAJMIN}/changelog" ]; then
    CHANGELOG="debian.hwe-${KMAJMIN}/changelog"
elif [ -f "debian/changelog" ]; then
    CHANGELOG="debian/changelog"
else
    CHANGELOG=$(find . -maxdepth 2 -name changelog -path "*/debian*/changelog" | head -1)
fi

if [ -n "$CHANGELOG" ]; then
    # Bump the version with +privasys suffix.
    head -1 "$CHANGELOG"
    sed -i "1s/)/+privasys)/" "$CHANGELOG"
    head -1 "$CHANGELOG"
fi

# ── Step 4: Build kernel .deb packages ──
echo ""
echo "=== Step 4: Building kernel (this takes a while) ==="

# Use Ubuntu's build system.
if [ -f "debian/rules" ]; then
    # For Ubuntu kernel trees, use the standard deb build.
    fakeroot debian/rules clean
    fakeroot debian/rules binary-headers binary-generic binary-perarch \
        2>&1 | tail -20 || {
        # Fall back to dpkg-buildpackage if rules targets don't exist.
        echo "Falling back to dpkg-buildpackage..."
        dpkg-buildpackage -b -uc -us -j"$JOBS" 2>&1 | tail -30
    }
else
    # Fallback: direct make deb-pkg.
    make olddefconfig
    make -j"$JOBS" bindeb-pkg LOCALVERSION=+privasys 2>&1 | tail -30
fi

# ── Step 5: Collect outputs ──
echo ""
echo "=== Step 5: Collecting .deb files ==="
mkdir -p "$OUTPUT_DIR"

# Find the built .deb files (they end up in the parent directory).
DEBS_FOUND=0
for deb in "$BUILD_DIR"/linux-image-*.deb "$BUILD_DIR"/linux-headers-*.deb "$BUILD_DIR"/linux-modules-*.deb; do
    if [ -f "$deb" ]; then
        cp -v "$deb" "$OUTPUT_DIR/"
        DEBS_FOUND=$((DEBS_FOUND + 1))
    fi
done

# Also check one level up.
for deb in "${BUILD_DIR}/../"linux-image-*.deb "${BUILD_DIR}/../"linux-headers-*.deb "${BUILD_DIR}/../"linux-modules-*.deb; do
    if [ -f "$deb" ]; then
        cp -v "$deb" "$OUTPUT_DIR/"
        DEBS_FOUND=$((DEBS_FOUND + 1))
    fi
done

if [ "$DEBS_FOUND" -eq 0 ]; then
    echo "WARNING: No .deb files found. Check build output above."
    find "$BUILD_DIR" -maxdepth 2 -name "*.deb" -ls
    exit 1
fi

echo ""
echo "=== Build complete ==="
echo "Kernel .deb files in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/*.deb 2>/dev/null
