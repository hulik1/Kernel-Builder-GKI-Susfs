#!/usr/bin/env bash
# scripts/inject_KernelSU-Next.sh
# Dynamic SuSFS integration module for KernelSU-Next

echo ">>> Executing Integration Module for KernelSU-Next..."

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> [DYNAMIC] Executing Automated Dynamic Transplant for KernelSU-Next..."
    
    echo ">>> 1. Cloning pristine official KernelSU-Next..."
    git clone "https://github.com/${UPSTREAM_REPO}.git" "${MANAGER_DIR}"
    
    # Prevent setup.sh from performing a redundant clone
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
    
    echo ">>> Executing native setup.sh to initialize branch..."
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${TARGET_BRANCH}"
    cd ..
    
    cd "${MANAGER_DIR}"

    # CAPTURE THIS IMMEDIATELY BEFORE ANY MERGING!
    UPSTREAM_HASH=$(git log -n 1 --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    echo "  -> Target Tag: $CALCULATED_TAG"

    echo ">>> 2. Fetching Pershoot's live laboratory..."
    git remote add pershoot https://github.com/pershoot/KernelSU-Next.git
    git fetch pershoot dev-susfs

    echo ">>> Configuring dummy Git identity for transplant operations..."
    git config --global user.email "runner@github.actions"
    git config --global user.name "GitHub Actions Canary"

    echo ">>> 3. Squashing and merging SuSFS features onto upstream tree..."
    if ! git merge --squash pershoot/dev-susfs; then
        echo "[-] CRITICAL: Merge conflict detected during squash merge!"
        git --no-pager diff --diff-filter=U
        exit 1
    fi
    
    git commit -m "Merge susfs features from pershoot"

    # SuSFS on 5.10 references the legacy SELinux state provided by KernelSU.
    # Keep the latest upstream; restore both the symbol and its runtime policy.
    if [ "${BASE_VER:-}" = "5.10" ]; then
        SELINUX_HIDE_FILE="kernel/feature/selinux_hide.c"
        if ! grep -qE '^[[:space:]]*struct[[:space:]]+selinux_state[[:space:]]+fake_state[[:space:]]*=' "$SELINUX_HIDE_FILE"; then
            echo ">>> [FIX] Restoring legacy SELinux fake_state for KernelSU-Next on 5.10..."
            patch --batch --forward --fuzz=0 -p1 <<'PATCH'
--- a/kernel/feature/selinux_hide.c
+++ b/kernel/feature/selinux_hide.c
@@ -36,6 +36,10 @@
 bool ksu_selinux_hide_enabled __read_mostly = false;
 bool ksu_selinux_hide_running __read_mostly = false;
 
+#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
+struct selinux_state fake_state = {0};
+#endif
+
 #ifdef CONFIG_KSU_SUSFS
 #define SUSFS_EXPORT
 #else
@@ -445,6 +449,11 @@
         return -EAGAIN;
     }
 
+#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
+    fake_state.initialized = true;
+    fake_state.policy = backup_sepolicy;
+#endif
+
     security_dump_masked_av_fn = find_kernel_symbol_exact("security_dump_masked_av");
     if (!security_dump_masked_av_fn) {
         pr_warn("security_dump_masked_av not found!\n");
PATCH
        fi

        # Stop early if upstream changes leave the legacy state incomplete.
        if ! grep -qE 'fake_state\.initialized[[:space:]]*=[[:space:]]*true' "$SELINUX_HIDE_FILE" ||
           ! grep -qE 'fake_state\.policy[[:space:]]*=[[:space:]]*backup_sepolicy' "$SELINUX_HIDE_FILE"; then
            echo "[-] KernelSU-Next 5.10 fake_state initialization is missing." >&2
            exit 1
        fi
    fi
    
    # Lock in variables for the Kbuild Gatekeeper
    UPSTREAM_BRANCH="${TARGET_BRANCH}"
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}")
    
else
    echo ">>> Safe fallback channel detected. Bypassing dynamic squash merge..."
    echo ">>> [STABLE] Cloning custom pipeline branch: ${KSU_VARIANT_REF}..."
    
    # Safest Git syntax: flags before the URL
    git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

    # Prevent setup.sh from performing a redundant clone
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"

    echo ">>> Executing native setup.sh..."
    cd common
    # FIX 1: Pass the dynamic reference
    bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
    cd ..

    cd "${MANAGER_DIR}"
    
    # FIX 2: Lock the upstream tracking variable to the dynamic branch for the Gatekeeper
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    
    # FIX 3: Fetch official upstream branch and calculate pristine Merge-Base
    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    RAW_BASE=$(git merge-base HEAD FETCH_HEAD)

    # FIX 4: Walk backward down the pristine mainline branch
    set +o pipefail
    UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    set -o pipefail
    
    # Calculate exact versions for the Sandbox Gatekeeper
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v3.2.0")
fi

# Step back out to kernel_workspace
cd .. 

# ---------------------------------------------------------
# KernelSU-Next Kbuild Hotfix (Universal)
# ---------------------------------------------------------
# Hotpatch strict Kbuild config check to prevent 'make clean' from crashing.
# Placed here universally to protect both dynamic and stable pipeline channels.
KBUILD_FILE="${MANAGER_DIR}/kernel/Kbuild"
if [ -f "$KBUILD_FILE" ]; then
    if grep -q "KernelSU requires either CONFIG_KPROBES" "$KBUILD_FILE"; then
        echo ">>> [HOTFIX] Bypassing strict Kbuild dependency check for the clean phase..."
        sed -i '/KernelSU requires either CONFIG_KPROBES/d' "$KBUILD_FILE"
    else
        echo ">>> [NOTICE] Strict Kbuild check not found! Upstream likely fixed this. You can remove this hotpatch."
    fi
fi

echo ">>> KernelSU-Next integration complete."
