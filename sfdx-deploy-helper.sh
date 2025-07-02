#!/bin/bash

# Salesforce Destructive Change Deploy Helper

# --- Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Return value of a pipeline is the value of the last command to exit with a non-zero status

# --- Argument Parsing ---
TARGET_ORG=""
BASE_BRANCH="main"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -o|--target-org)
            TARGET_ORG="$2"
            shift 2
            ;;
        -b|--base-branch)
            BASE_BRANCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$TARGET_ORG" ]; then
    echo "Error: Target organization alias is required."
    echo "Usage: $0 -o|--target-org <org_alias> [-b|--base-branch <branch_name>]"
    exit 1
fi

# --- Main Logic ---
echo "🚀 Starting Salesforce Deploy Helper..."
echo "-----------------------------------------"
echo "Target Organization: $TARGET_ORG"
echo "Base Branch for diff: $BASE_BRANCH"
echo "-----------------------------------------"

# --- 1. Generate Delta Package ---
TMP_DIR="tmp_deploy"
echo "[1/5] Generating delta package against branch '$BASE_BRANCH'..."
if [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
fi
mkdir "$TMP_DIR"

sfdx sgd:source:delta --to "HEAD" --from "$BASE_BRANCH" --output "$TMP_DIR/" > /dev/null

echo "✅ Delta package generated in '$TMP_DIR' directory."


# --- 2. Analyze Destructive Changes ---
echo "
[2/5] Analyzing destructive changes..."
DESTRUCTIVE_XML="$TMP_DIR/destructiveChanges.xml"
DELETED_MEMBERS=()

if [ -f "$DESTRUCTIVE_XML" ]; then
    mapfile -t DELETED_MEMBERS < <(grep -o '<members>.*</members>' "$DESTRUCTIVE_XML" | sed -e 's/<members>//' -e 's/\/members>//')

    if [ ${#DELETED_MEMBERS[@]} -gt 0 ]; then
        echo "🔍 Found ${#DELETED_MEMBERS[@]} component(s) to be deleted:"
        for member in "${DELETED_MEMBERS[@]}"; do
            echo "  - $member"
        done
    else
        echo "✅ No components to delete."
    fi
else
    echo "✅ No destructive changes found."
fi


# --- 3. Find Dependencies in Source Code ---
echo "
[3/5] Searching for dependencies in source code..."
DEPENDENCY_FILES=()
if [ ${#DELETED_MEMBERS[@]} -gt 0 ]; then
    TMP_DEP_FILE=$(mktemp)
    for member in "${DELETED_MEMBERS[@]}"; do
        grep -lr "$member" force-app/ >> "$TMP_DEP_FILE" || true
    done
    mapfile -t DEPENDENCY_FILES < <(sort -u "$TMP_DEP_FILE")
    rm "$TMP_DEP_FILE"

    if [ ${#DEPENDENCY_FILES[@]} -gt 0 ]; then
        echo "🔍 Found dependencies in ${#DEPENDENCY_FILES[@]} file(s):"
        for file in "${DEPENDENCY_FILES[@]}"; do
            echo "  - $file"
        done
    else
        echo "✅ No dependencies found."
    fi
fi

# --- 4. Temporarily Neutralize Dependencies ---
STASH_CREATED=0
function cleanup() {
    echo "
INFO: Cleaning up..."
    if [ $STASH_CREATED -eq 1 ]; then
        echo "INFO: Restoring original source files by popping stash..."
        git stash pop > /dev/null 2>&1 || echo "WARNING: git stash pop failed. Manual cleanup may be required."
    fi
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    echo "Cleanup complete."
}
trap cleanup EXIT

if [ ${#DEPENDENCY_FILES[@]} -gt 0 ]; then
    echo "
[4/5] Neutralizing dependencies..."
    echo "INFO: Stashing uncommitted changes..."
    git stash save "sfdx-deploy-helper-temp-stash" > /dev/null
    STASH_CREATED=1

    echo "INFO: Commenting out dependencies in files..."
    for file in "${DEPENDENCY_FILES[@]}"; do
        for member in "${DELETED_MEMBERS[@]}"; do
            safe_member=$(printf '%s
' "$member" | sed 's/[&/\\]/\\&/g')
            sed -i -e "s/.*${safe_member}.*/\/\/ SF-HELPER: Auto-commented for deploy. Original line: &/" "$file"
        done
    done
    echo "✅ Dependencies neutralized."
fi

# --- 5. Execute Deployment ---
echo "
[5/5] Deploying to org '$TARGET_ORG'..."

DEPLOY_COMMAND="sf project deploy start --manifest \"$TMP_DIR/package.xml\" --target-org \"$TARGET_ORG\" --test-level RunLocalTests"

if [ -f "$DESTRUCTIVE_XML" ]; then
    DEPLOY_COMMAND="$DEPLOY_COMMAND --pre-destructive-changes \"$DESTRUCTIVE_XML\""
fi

eval $DEPLOY_COMMAND

echo "
🎉 Deployment successful! 🎉"