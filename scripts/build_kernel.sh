#!/usr/bin/env bash
set -euo pipefail

WITH_CUSTOM=${WITH_CUSTOM:-false}

echo "=== Initializing Execution Engine ==="

cd kernel_workspace
mkdir -p ../out out/dist

echo ">>> Marking repo as clean (sanitizes all custom configuration & source modifications)..."
# Dynamically safeguards all modifications
git -C common ls-files -m | xargs -r git -C common update-index --assume-unchanged

# Build method
if [ "$BASE_VER" != "5.10" ] && [ -f "tools/bazel" ]; then
    echo ">>> Modern Kleaf/Bazel ecosystem detected for $BASE_VER..."
    # Enforce standard sandboxing, disable trimming, and inject MAKEFLAGS dynamically

    tools/bazel run --config=stamp \
      --notrim \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=STABLE_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      //common:kernel_aarch64_dist \
      -- \
      --destdir=out/dist
else
    echo ">>> Legacy Hermetic Make ecosystem detected (5.10 or fallback)..."

    mkdir -p out/dist

    # 1. Physically patch the hardcoded build configs so they cannot override our settings
    echo ">>> Disabling strict mode, trimming and check_defconfig in 5.10 build.config files..."
    sed -i 's/KMI_SYMBOL_LIST_STRICT_MODE=1/KMI_SYMBOL_LIST_STRICT_MODE=0/g' common/build.config.* 2>/dev/null || true
    sed -i 's/TRIM_NONLISTED_KMI=1/TRIM_NONLISTED_KMI=0/g' common/build.config.* 2>/dev/null || true
    # WildKernels does the same for legacy 5.10: custom gki_defconfig entries
    # such as BBRv3 must not be rejected by the canonical savedefconfig check.
    sed -i 's/check_defconfig//g' common/build.config.gki 2>/dev/null || true

    # 2. Export standard environment variables for legacy build.sh
    export KERNEL_DIR="common"
    export BUILD_CONFIG="common/build.config.gki.aarch64"
    export SOURCE_DATE_EPOCH="$OFFICIAL_DATE"

    # 3. Build one effective legacy fragment. Custom settings are optional,
    #    but BBRv3 is mandatory whenever its source patch is present.
    LEGACY_FRAGMENT="common/arch/arm64/configs/custom_legacy.fragment"

    if [ "$WITH_CUSTOM" != "true" ]; then
        rm -f "$LEGACY_FRAGMENT"
    fi

    if grep -qE '^config[[:space:]]+TCP_CONG_BBR3$' common/net/ipv4/Kconfig 2>/dev/null; then
        echo ">>> BBRv3 source detected. Forcing required 5.10 Kconfig options..."

        # Android 12 / 5.10 legacy build.sh builds from gki_defconfig. Mirror the
        # proven WildKernels approach and write mandatory BBRv3 settings there
        # directly, before build/build.sh runs make gki_defconfig.
        DEFCONFIG="common/arch/arm64/configs/gki_defconfig"
        if [ ! -f "$DEFCONFIG" ]; then
            echo "[-] ERROR: $DEFCONFIG not found; cannot enable BBRv3." >&2
            exit 1
        fi

        set_gki_config() {
            local key="$1"
            local value="$2"

            if grep -q "^${key}=" "$DEFCONFIG"; then
                sed -i "s|^${key}=.*|${key}=${value}|" "$DEFCONFIG"
            elif grep -q "^# ${key} is not set$" "$DEFCONFIG"; then
                sed -i "s|^# ${key} is not set$|${key}=${value}|" "$DEFCONFIG"
            else
                echo "${key}=${value}" >> "$DEFCONFIG"
            fi
        }

        set_gki_config CONFIG_TCP_CONG_ADVANCED y
        set_gki_config CONFIG_TCP_CONG_BBR y
        set_gki_config CONFIG_TCP_CONG_BBR3 y
        set_gki_config CONFIG_NET_SCHED y
        set_gki_config CONFIG_NET_SCH_FQ y

        echo ">>> BBRv3 written directly to $DEFCONFIG"
        grep -E '^CONFIG_(TCP_CONG_ADVANCED|TCP_CONG_BBR|TCP_CONG_BBR3|NET_SCHED|NET_SCH_FQ)=' "$DEFCONFIG" || true

        # Keep the legacy fragment in sync for custom-config reporting and for
        # trees where the optional post-defconfig hook is available.
        touch "$LEGACY_FRAGMENT"

        # Remove stale/duplicate values before appending the authoritative settings.
        sed -i '/^CONFIG_TCP_CONG_BBR3=/d;/^# CONFIG_TCP_CONG_BBR3 is not set/d' "$LEGACY_FRAGMENT"
        sed -i '/^CONFIG_NET_SCHED=/d;/^# CONFIG_NET_SCHED is not set/d' "$LEGACY_FRAGMENT"
        sed -i '/^CONFIG_NET_SCH_FQ=/d;/^# CONFIG_NET_SCH_FQ is not set/d' "$LEGACY_FRAGMENT"

        cat >> "$LEGACY_FRAGMENT" <<'EOF'
CONFIG_TCP_CONG_BBR3=y
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_FQ=y
EOF
    fi

    # Android 12 / 5.10 legacy build.sh does not consume EXTRA_DEFCONFIG_FRAGMENTS.
    # build.config.gki.aarch64 does, however, source GKI_DEFCONFIG_FRAGMENT after
    # build.config.gki. Use that supported hook to extend POST_DEFCONFIG_CMDS and
    # merge our fragment into the actual OUT_DIR/.config after gki_defconfig.
    if [ -s "$LEGACY_FRAGMENT" ]; then
        LEGACY_KCONFIG_HOOK="$(pwd)/common/build.config.gki.builder_fragment"

        cat > "$LEGACY_KCONFIG_HOOK" <<'EOF'
apply_builder_kconfig_fragment() {
    local fragment="${ROOT_DIR}/${KERNEL_DIR}/arch/arm64/configs/custom_legacy.fragment"

    if [ ! -s "$fragment" ]; then
        return 0
    fi

    echo ">>> Applying legacy builder Kconfig fragment to ${OUT_DIR}/.config..."

    KCONFIG_CONFIG="${OUT_DIR}/.config" \
        "${ROOT_DIR}/${KERNEL_DIR}/scripts/kconfig/merge_config.sh" \
        -m -r "${OUT_DIR}/.config" "$fragment"

    # Resolve Kconfig dependencies after the merge. The hard validation below
    # will fail the build if a requested mandatory option still cannot survive.
    (cd "${OUT_DIR}" && make ${CC_LD_ARG} O="${OUT_DIR}" olddefconfig)
}

POST_DEFCONFIG_CMDS="${POST_DEFCONFIG_CMDS:+${POST_DEFCONFIG_CMDS} && }apply_builder_kconfig_fragment"
EOF

        export GKI_DEFCONFIG_FRAGMENT="$LEGACY_KCONFIG_HOOK"
        echo ">>> Legacy defconfig hook enabled: $GKI_DEFCONFIG_FRAGMENT"
    else
        unset GKI_DEFCONFIG_FRAGMENT || true
        echo ">>> No legacy defconfig fragment requested."
    fi

    export DIST_DIR="out/dist"

    # Inject official hash and Make overrides
    export EXTRA_LINUX_VERSION="-g${OFFICIAL_HASH}"

    # 4. Run the legacy orchestration script
    if [ -f "build/build.sh" ]; then
        echo "[+] Invoking build/build.sh..."
        bash build/build.sh
    elif [ -f "build.sh" ]; then
        echo "[+] Invoking build.sh..."
        bash build.sh
    else
        echo "[-] ERROR: Legacy build.sh orchestrator not found!" >&2
        exit 1
    fi
fi

IMAGE_PATH="$(find out/dist -type f -name 'Image' -print -quit)"
if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"

# --- HARD BBRv3 VALIDATION ---
# If the BBRv3 patch is present in the source tree, never allow a green build
# unless CONFIG_TCP_CONG_BBR3 actually survived the final kernel configuration.
if grep -qE '^config[[:space:]]+TCP_CONG_BBR3$' common/net/ipv4/Kconfig 2>/dev/null; then
    echo "::group::BBRv3 hard validation"
    echo ">>> BBRv3 source detected; validating final build configuration..."

    FINAL_CONFIG=""
    if [ -f "out/dist/config.gz" ]; then
        FINAL_CONFIG="out/dist/config.gz"
    elif [ -f "out/dist/.config" ]; then
        FINAL_CONFIG="out/dist/.config"
    else
        FINAL_CONFIG=$(find out/ -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
    fi

    BBR3_OK=false
    FQ_OK=false

    if [ -n "$FINAL_CONFIG" ]; then
        echo ">>> Checking: $FINAL_CONFIG"
        if [[ "$FINAL_CONFIG" == *.gz ]]; then
            zgrep -q '^CONFIG_TCP_CONG_BBR3=y$' "$FINAL_CONFIG" && BBR3_OK=true || true
            zgrep -q '^CONFIG_NET_SCH_FQ=y$' "$FINAL_CONFIG" && FQ_OK=true || true
        else
            grep -q '^CONFIG_TCP_CONG_BBR3=y$' "$FINAL_CONFIG" && BBR3_OK=true || true
            grep -q '^CONFIG_NET_SCH_FQ=y$' "$FINAL_CONFIG" && FQ_OK=true || true
        fi
    else
        echo "[!] Final .config/config.gz not found; falling back to object validation."
        if find out/ -type f -name 'tcp_bbr3.o' -print -quit 2>/dev/null | grep -q .; then
            BBR3_OK=true
        fi
        # FQ is a standard scheduler; only hard-fail BBR3 itself when no final config is available.
        FQ_OK=true
    fi

    if [ "$BBR3_OK" != "true" ]; then
        echo "[-] ERROR: BBRv3 patch is present, but CONFIG_TCP_CONG_BBR3=y is missing from the built kernel." >&2
        echo "[-] Refusing to publish a kernel without BBRv3." >&2
        exit 1
    fi

    if [ "$FQ_OK" != "true" ]; then
        echo "[-] ERROR: CONFIG_NET_SCH_FQ=y is missing; BBRv3 pacing support is incomplete." >&2
        exit 1
    fi

    echo "[+] BBRv3 validation passed: CONFIG_TCP_CONG_BBR3=y"
    echo "[+] FQ validation passed: CONFIG_NET_SCH_FQ=y"
    echo "::endgroup::"
fi

cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Extracting kernel runtime version string..."
# Try matching the standard format first, then fall back to a looser grep for legacy banners
KERNEL_VERSION_STRING=$(strings ../out/Image | grep -E "Linux version [0-9]" | head -n 1 || true)

if [ -z "$KERNEL_VERSION_STRING" ]; then
    KERNEL_VERSION_STRING=$(strings ../out/Image | grep -i "Linux version" | head -n 1 || true)
fi

if [ -n "$KERNEL_VERSION_STRING" ]; then
    echo "    $KERNEL_VERSION_STRING"
else
    echo "    [!] Notice: Could not read raw banner string directly from compiled Image binary."
fi

# --- DYNAMIC KCONFIG VALIDATION REPORT ---
if [ "$WITH_CUSTOM" = "true" ]; then
    echo "::group::Custom Kconfig Integration Report"
    echo ""
    echo "=============================================="
    echo " CUSTOM KCONFIG VALIDATION REPORT             "
    echo "=============================================="

    FRAGMENT_FILE="../tools/custom.fragment"

    if [ ! -f "$FRAGMENT_FILE" ]; then
        echo "[-] Notice: tools/custom.fragment not found. Skipping validation."
    else
        # Locate the definitive compiled configuration source
        CONFIG_SRC=""
        if [ -f "out/dist/config.gz" ]; then
            CONFIG_SRC="out/dist/config.gz"
        elif [ -f "out/dist/.config" ]; then
            CONFIG_SRC="out/dist/.config"
        else
            CONFIG_SRC=$(find out/ -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
        fi

        if [ -z "$CONFIG_SRC" ]; then
            echo "[!] WARN: Could not locate compiled kernel configuration target."
        else
            echo ">>> Extracting definitions from: $CONFIG_SRC"
            echo "----------------------------------------------"

            # Extract requested configs from fragment, ignoring comments and empty lines
            REQUESTED_CONFIGS=$(grep -E '^CONFIG_' "$FRAGMENT_FILE" | cut -d'=' -f1 || true)

            if [ -z "$REQUESTED_CONFIGS" ]; then
                echo "  [-] No active custom configs found in fragment."
            else
                for CFG in $REQUESTED_CONFIGS; do
                    # Search compiled config for the requested variable
                    if [[ "$CONFIG_SRC" == *.gz ]]; then
                        VAL=$(zgrep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    else
                        VAL=$(grep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    fi

                    # Print clean validation status
                    if [ "$VAL" = "y" ]; then
                        printf "  [ PASS ] %-40s = %s\n" "$CFG" "$VAL"
                    elif [ "$VAL" = "m" ]; then
                        printf "  [ WARN ] %-40s = %s (Module)\n" "$CFG" "$VAL"
                    else
                        printf "  [ DROP ] %-40s = MISSING/OVERRIDDEN\n" "$CFG"
                    fi
                done
            fi
        fi
    fi

    echo "=============================================="
    echo "::endgroup::"
fi

cd ..
echo ">>> Build execution loop completed"
