#!/bin/bash

# Salesforce Destructive Change Deploy Helper

# --- Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Return value of a pipeline is the value of the last command to exit with a non-zero status

# --- Argument Parsing ---
TARGET_ORG=""
BASE_BRANCH="main"
MODE="git-diff" # Default mode

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
        -m|--mode)
            MODE="$2"
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
    echo "Usage: $0 -o|--target-org <org_alias> [-b|--base-branch <branch_name>] [-m|--mode <git-diff|org-snapshot>]"
    exit 1
fi

# --- Main Logic ---
echo "🚀 Starting Salesforce Deploy Helper..."
echo "-----------------------------------------"
echo "Target Organization: $TARGET_ORG"
echo "Deployment Mode: $MODE"
if [ "$MODE" == "git-diff" ]; then
    echo "Base Branch for diff: $BASE_BRANCH"
fi
echo "-----------------------------------------"

case "$MODE" in
    "git-diff")
        # --- 1. Generate Delta Package ---
        TMP_DIR="tmp_deploy"
        echo "[1/5] Generating delta package against branch '$BASE_BRANCH'..."
        if [ -d "$TMP_DIR" ]; then
            rm -rf "$TMP_DIR"
        fi
        mkdir "$TMP_DIR"

                sf sgd:source:delta --to "HEAD" --from "$BASE_BRANCH" --generate-delta --output-dir "$TMP_DIR/" > "$TMP_DIR/sgd_output.log" 2>&1

        echo "DEBUG: Contents of $TMP_DIR:"
        ls -l "$TMP_DIR"
        cat "$TMP_DIR/sgd_output.log" # Add this line to display the log content

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

        DEPLOY_COMMAND="sf project deploy start --manifest \"$TMP_DIR/package/package.xml\" --target-org \"$TARGET_ORG\" --test-level RunLocalTests"

        if [ -f "$DESTRUCTIVE_XML" ]; then
            DEPLOY_COMMAND="$DEPLOY_COMMAND --pre-destructive-changes \"$DESTRUCTIVE_XML\""
        fi

        eval $DEPLOY_COMMAND

        echo "
🎉 Deployment successful! 🎉"
        ;;
    "org-snapshot")
        echo "Org Snapshot Comparison Based Deployment (Under Development)"
        echo "This mode will compare the target Salesforce org with local source and generate a deploy package."
        # --- 2.2 Acquire Organization Snapshot ---
        ORG_SNAPSHOT_DIR="tmp_org_snapshot"
        echo "[1/X] Acquiring organization snapshot from '$TARGET_ORG'..."
        if [ -d "$ORG_SNAPSHOT_DIR" ]; then
            rm -rf "$ORG_SNAPSHOT_DIR"
        fi
        mkdir "$ORG_SNAPSHOT_DIR"

        # Retrieve all metadata from the target org. This can be time-consuming for large orgs.
        # A more refined approach might involve retrieving a package.xml first, then retrieving based on that.
        sf project retrieve start -m "all" -r "$ORG_SNAPSHOT_DIR" -o "$TARGET_ORG"

        echo "✅ Organization snapshot acquired in '$ORG_SNAPSHOT_DIR' directory."
        # --- 2.3 Compare with Local Source and Generate Manifests ---
        DIFF_DIR="tmp_diff_package"
        echo "[2/X] Comparing organization snapshot with local source and generating manifests..."
        if [ -d "$DIFF_DIR" ]; then
            rm -rf "$DIFF_DIR"
        fi
        mkdir "$DIFF_DIR"

        # Compare the retrieved snapshot with the local force-app directory
        # This command generates package.xml and destructiveChanges.xml based on the diff
        sf project deploy diff --source-dir force-app --output-dir "$DIFF_DIR" --target-org "$TARGET_ORG"

        echo "✅ Diff package generated in '$DIFF_DIR' directory."

        # --- 2.4 Analyze Destructive Changes (from diff) ---
        DESTRUCTIVE_XML="$DIFF_DIR/destructiveChanges.xml"
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

        # --- 2.5 Execute Deployment and Cleanup ---
        echo "\n[3/X] Deploying to org '$TARGET_ORG'..."

        DEPLOY_COMMAND="sf project deploy start --manifest \"$DIFF_DIR/package.xml\" --target-org \"$TARGET_ORG\" --test-level RunLocalTests"

        if [ -f "$DESTRUCTIVE_XML" ]; then
            DEPLOY_COMMAND="$DEPLOY_COMMAND --pre-destructive-changes \"$DESTRUCTIVE_XML\""
        fi

        eval $DEPLOY_COMMAND

        echo "\n🎉 Deployment successful! 🎉"

        # Cleanup temporary directories
        echo "\nINFO: Cleaning up..."
        if [ -d "$ORG_SNAPSHOT_DIR" ]; then
            rm -rf "$ORG_SNAPSHOT_DIR"
        fi
        if [ -d "$DIFF_DIR" ]; then
            rm -rf "$DIFF_DIR"
        fi
        echo "Cleanup complete."
        ;;
    *)
        echo "Error: Invalid mode specified. Use 'git-diff' or 'org-snapshot'."
        exit 1
        ;;
esac