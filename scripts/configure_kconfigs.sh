#!/usr/bin/env bash
set -euo pipefail

# Configuration: Toggle custom Kconfig integration via ENV (Defaults to false)
WITH_CUSTOM=${WITH_CUSTOM:-false}

# Define the source fragment relative to the script execution point
FRAGMENT_SRC="$(pwd)/tools/custom.fragment"

echo "=== Configuring Kconfigs & ABI Neutralization ==="

cd kernel_workspace

# ========================================================================
# 1. NEUTRALIZE LEGACY ABI PROTECTED EXPORTS (5.10 through 6.6)
# ========================================================================
echo ">>> Neutralizing legacy ABI protected exports lists..."
for f in common/android/abi_gki_protected_exports* android/abi_gki_protected_exports*; do
    [ -f "$f" ] && > "$f" || true
done

# Enter the common kernel source tree
cd common

# ========================================================================
# 2. NEUTRALIZE MODERN BAZEL TRIMMING & STRICT MODE (6.1, 6.6, 6.12+)
# ========================================================================
if [ -f "BUILD.bazel" ]; then
    echo ">>> Modern Bazel detected: Disabling module trimming and strict ABI mode..."

    # Match either "trim_nonlisted_kmi": True (6.6) or trim_nonlisted_kmi = True (6.12+)
    sed -i -E 's/(["\x27]?trim_nonlisted_kmi["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel

    # Match either "kmi_symbol_list_strict_mode": True (6.1/6.6) or kmi_symbol_list_strict_mode = True (6.12+)
    sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel
fi

# ========================================================================
# 3. INTEGRATE CUSTOM KCONFIG FRAGMENT (Optional)
# ========================================================================
if [ "$WITH_CUSTOM" = "true" ]; then
    if [ ! -f "$FRAGMENT_SRC" ]; then
        echo "[-] Error: Fragment file not found at $FRAGMENT_SRC"
        exit 1
    fi

    echo ">>> Integrating Kconfig Configurations from $FRAGMENT_SRC..."

    if [ -f "BUILD.bazel" ]; then
        echo ">>> Exposing custom fragment to Bazel sandbox..."
        cp "$FRAGMENT_SRC" custom_fragment

        if grep -q '"kernel_aarch64": {' BUILD.bazel; then
            # ----------------------------------------------------
            # KERNEL 6.1 / 6.6 (Dictionary-style target_configs)
            # ----------------------------------------------------
            echo ">>> Detected Dictionary-style Bazel config (6.1 / 6.6). Injecting fragment..."
            sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' BUILD.bazel

        elif grep -q 'name = "kernel_aarch64",' BUILD.bazel; then
            # ----------------------------------------------------
            # KERNEL 6.12+ (Rule macro style common_kernel)
            # ----------------------------------------------------
            echo ">>> Detected Rule macro Bazel config (6.12+). Injecting fragment..."
            sed -i '/name = "kernel_aarch64",/a \    defconfig_fragments = ["custom_fragment"],' BUILD.bazel

        else
            echo "[-] Error: Could not locate 'kernel_aarch64' target in BUILD.bazel to inject fragment."
            exit 1
        fi

    else
        # ----------------------------------------------------
        # KERNEL 5.10 / 5.15 (Legacy Make Ecosystem)
        # ----------------------------------------------------
        echo ">>> Legacy Make detected (5.10 / 5.15): Copying fragment..."
        cp "$FRAGMENT_SRC" arch/arm64/configs/custom_legacy.fragment
    fi
else
    echo ">>> Skipping custom Kconfig configuration..."
fi

# Return to root workspace directory
cd ../..

echo ">>> Kconfig & ABI configuration phase complete."
