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
EXACT_RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success&per_page=50")

RUN_IDS=$(echo "$EXACT_RUNS" | jq -r '.workflow_runs[]?.id // empty')

for ID in $RUN_IDS; do
    echo ">>> Checking exact-match Run ID: $ID for artifacts..."
    ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
    
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
# 2. WALK BACKWARDS THROUGH MAIN COMMITS
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Exact match missing or lacked artifacts. Walking backward through recent successful main branch runs..."
    
    # The API returns these ordered from newest to oldest by default
    RECENT_RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs?branch=main&status=success&per_page=20")
    
    RECENT_RUN_IDS=$(echo "$RECENT_RUNS" | jq -r '.workflow_runs[]?.id // empty')
    
    for ID in $RECENT_RUN_IDS; do
        echo ">>> Checking previous Run ID: $ID for artifacts..."
        ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
        
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
# 3. DOWNLOAD OR GRACEFUL EXIT
# ==========================================
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Warning: Exhausted search. Failed to locate ANY valid Manager artifacts for $REPO."
    echo "[-] Continuing CI run to completion without staging Manager APKs."
    exit 0
fi

mkdir -p manager_apk
COUNTER=1

IFS=$'\n'
for ENTRY in $DOWNLOAD_URLS; do
  TYPE=$(echo "$ENTRY" | cut -d'|' -f1)
  URL=$(echo "$ENTRY" | cut -d'|' -f2)
  
  if [[ "$TYPE" == *"ZIP"* ]] || [[ "$TYPE" == "ARTIFACT" ]]; then
      echo ">>> Downloading ZIP archive $COUNTER..."
      curl -s -L \
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

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/
