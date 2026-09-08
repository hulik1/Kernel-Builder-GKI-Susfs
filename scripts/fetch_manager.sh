#!/bin/bash
# scripts/fetch_manager.sh

set -euo pipefail

VARIANT="${1}"
GH_TOKEN="${2}"
UPSTREAM_HASH="${3:-}"

# ==========================================
# ROOT MANAGER FETCH LOGIC
# ==========================================
echo ">>> Mapping selected variant to upstream repository..."
if [[ "${VARIANT}" == "KernelSU-Next" ]]; then
    REPO="KernelSU-Next/KernelSU-Next"
elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
    REPO="SukiSU-Ultra/SukiSU-Ultra"
elif [[ "${VARIANT}" == "ReSukiSU" ]]; then
    REPO="ReSukiSU/ReSukiSU"
elif [[ "${VARIANT}" == "KernelSU" ]]; then
    REPO="tiann/KernelSU"
else
    echo "[-] Error: Unsupported Variant '${VARIANT}'." >&2
    exit 1
fi

echo ">>> Searching $REPO for a Release Manager..."

DOWNLOAD_URLS=""

# ==========================================
# 1. EXACT HASH MATCH
# ==========================================
echo ">>> Checking for exact upstream hash: ${UPSTREAM_HASH}"
EXACT_RUNS=$(curl -fsSL --retry 3 -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success&per_page=50")

RUN_IDS=$(echo "$EXACT_RUNS" | jq -r '.workflow_runs[]?.id // empty')

for ID in $RUN_IDS; do
    echo ">>> Checking exact-match Run ID: $ID for artifacts..."
    ARTIFACTS_JSON=$(curl -fsSL --retry 3 -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts?per_page=100")
    
    DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
      .artifacts[]? 
      | select(.name | test("(?i)(manager|kernelsu[_-]v)"))
      | select(.name | test("(?i)(debug|mappings|gradle)") | not)
      | select(.name | test("(?i)(armeabi-v7a|universal|x86_64)") | not)
      | select(.expired == false)
      | "ARTIFACT|\(.archive_download_url)" // empty')

    if [ -n "$DOWNLOAD_URLS" ]; then
        echo ">>> Success! Found unexpired exact Manager artifacts in Run ID: $ID"
        break
    fi
done

# ==========================================
# 2. WALK BACKWARDS THROUGH THE UPSTREAM DEFAULT BRANCH
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    # Upstream branch names differ between variants and may change over time.
    # KernelSU-Next, for example, publishes Manager CI artifacts from dev.
    REPO_JSON=$(curl -fsSL --retry 3 -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO")
    DEFAULT_BRANCH=$(echo "$REPO_JSON" | jq -er '.default_branch | select(type == "string" and length > 0)')
    BRANCH_QUERY=$(jq -rn --arg branch "$DEFAULT_BRANCH" '$branch | @uri')

    echo "[-] Exact match missing or lacked artifacts. Walking backward through recent successful $DEFAULT_BRANCH branch runs..."
    
    # The API returns these ordered from newest to oldest by default
    RECENT_RUNS=$(curl -fsSL --retry 3 -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs?branch=${BRANCH_QUERY}&status=success&per_page=20")
    
    RECENT_RUN_IDS=$(echo "$RECENT_RUNS" | jq -r '.workflow_runs[]?.id // empty')
    
    for ID in $RECENT_RUN_IDS; do
        echo ">>> Checking previous Run ID: $ID for artifacts..."
        ARTIFACTS_JSON=$(curl -fsSL --retry 3 -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts?per_page=100")
        
        DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
          .artifacts[]? 
          | select(.name | test("(?i)(manager|kernelsu[_-]v)"))
          | select(.name | test("(?i)(debug|mappings|gradle)") | not)
          | select(.name | test("(?i)(armeabi-v7a|universal|x86_64)") | not)
          | select(.expired == false)
          | "ARTIFACT|\(.archive_download_url)" // empty')

        if [ -n "$DOWNLOAD_URLS" ]; then
            echo ">>> Success! Found unexpired fallback Manager artifacts in Run ID: $ID"
            break
        fi
    done
fi

# ==========================================
# 3. DOWNLOAD OR REPORT MISSING MANAGER
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Error: Failed to locate unexpired Manager artifacts for $REPO (commit $UPSTREAM_HASH or branch $DEFAULT_BRANCH)." >&2
    exit 1
fi

mkdir -p manager_apk
COUNTER=1

IFS=$'\n'
for ENTRY in $DOWNLOAD_URLS; do
  TYPE=$(echo "$ENTRY" | cut -d'|' -f1)
  URL=$(echo "$ENTRY" | cut -d'|' -f2)
  
  if [[ "$TYPE" == *"ZIP"* ]] || [[ "$TYPE" == "ARTIFACT" ]]; then
      echo ">>> Downloading ZIP archive $COUNTER..."
      curl -fsSL --retry 3 \
        -H "Authorization: token $GH_TOKEN" \
        -o "manager_${COUNTER}.zip" "$URL"
      
      echo ">>> Extracting archive..."
      unzip -q -o "manager_${COUNTER}.zip" -d manager_apk/
      rm "manager_${COUNTER}.zip"
  fi
  
  COUNTER=$((COUNTER+1))
done
unset IFS

echo ">>> Cleaning up unnecessary architectures..."
find manager_apk/ -type f \( -name "*armeabi-v7a*" -o -name "*universal*" -o -name "*x86_64*" \) -exec rm -f {} +

# Match the upload step's path so a green fetch always provides an APK.
if ! compgen -G 'manager_apk/*.apk' > /dev/null; then
    echo "[-] Error: Downloaded Manager artifacts contain no supported APKs in manager_apk/." >&2
    exit 1
fi

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/
