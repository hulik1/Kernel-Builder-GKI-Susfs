#!/usr/bin/env bash
set -euo pipefail

WITH_CUSTOM=${WITH_CUSTOM:-false}
FRAGMENT_SRC="$(pwd)/tools/custom.fragment"
BASE_VER=${BASE_VER:-}

echo "=== Configuring Kconfigs & ABI Neutralization for Kernel $BASE_VER ==="

cd kernel_workspace

# 1. NEUTRALIZE LEGACY ABI PROTECTED EXPORTS (5.10 through 6.6)
for f in common/android/abi_gki_protected_exports* android/abi_gki_protected_exports*; do
    [ -f "$f" ] && > "$f" || true
done

cd common

# 2. NEUTRALIZE MODERN BAZEL TRIMMING & STRICT MODE
case "$BASE_VER" in
    5.10)
        # Legacy Make ecosystem has no BUILD.bazel flags to patch
        echo ">>> Legacy 5.10: Skipping Bazel ABI patches."
        ;;
    5.15|6.1)
        echo ">>> Bazel 5.15/6.1: Disabling strict ABI mode..."
        sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel
        ;;
    *)
        # Assumes 6.6 and 6.12+ (Android 15+)
        echo ">>> Bazel 6.6+: Disabling strict ABI mode and module trimming..."
        sed -i -E 's/(["\x27]?trim_nonlisted_kmi["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel
        sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel
        ;;
esac

# 3. INTEGRATE CUSTOM KCONFIG FRAGMENT
if [ "$WITH_CUSTOM" = "true" ]; then
    if [ ! -f "$FRAGMENT_SRC" ]; then
        echo "[-] Error: Fragment not found at $FRAGMENT_SRC"
        exit 1
    fi

    case "$BASE_VER" in
        5.10)
            cp "$FRAGMENT_SRC" arch/arm64/configs/custom_legacy.fragment
            ;;
        5.15|6.1)
            cp "$FRAGMENT_SRC" custom_fragment
            sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' BUILD.bazel
            ;;
        *) 
            # Assumes 6.6 and 6.12+ (Android 15+)
            cp "$FRAGMENT_SRC" custom_fragment
            sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' BUILD.bazel
            ;;
    esac
fi

cd ../..
echo ">>> Configuration complete."
