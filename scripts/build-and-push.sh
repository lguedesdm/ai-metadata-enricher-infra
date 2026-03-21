#!/usr/bin/env bash
# =============================================================================
# build-and-push.sh
# =============================================================================
# Builds and pushes the Orchestrator container image and deploys the Bridge
# Function code to Azure.
#
# Usage:
#   ./scripts/build-and-push.sh \
#     --environment prod \
#     --project-name ai-metadata \
#     --resource-group rg-ai-metadata-prod \
#     --app-repo-path ../ai-metadata-enricher
# =============================================================================

set -uo pipefail

ENVIRONMENT=""
PROJECT="ai-metadata"
RESOURCE_GROUP=""
APP_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)     ENVIRONMENT="$2";     shift 2 ;;
    --project-name)    PROJECT="$2";         shift 2 ;;
    --resource-group)  RESOURCE_GROUP="$2";  shift 2 ;;
    --app-repo-path)   APP_REPO="$2";        shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENVIRONMENT" || -z "$RESOURCE_GROUP" || -z "$APP_REPO" ]]; then
  echo "ERROR: --environment, --resource-group, and --app-repo-path required" >&2
  exit 1
fi

PREFIX="${PROJECT}-${ENVIRONMENT}"
PREFIX_NO_DASH="${PROJECT//-/}${ENVIRONMENT//-/}"
ACR="cr${PREFIX_NO_DASH:0:20}"
IMAGE_TAG="${ENVIRONMENT}"
IMAGE_NAME="ai-metadata-orchestrator"
FULL_IMAGE="${ACR}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}"
FUNC_NAME="func-bridge-${PREFIX}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo "=== Build & Push: ${ENVIRONMENT} ==="
echo "  ACR:       ${ACR}"
echo "  Image:     ${FULL_IMAGE}"
echo "  Function:  ${FUNC_NAME}"
echo "  App Repo:  ${APP_REPO}"
echo ""

# -------------------------------------------------------------------------
# Step 1: Build Orchestrator Docker Image
# -------------------------------------------------------------------------
echo "--- Step 1: Build Docker Image ---"
if ! command -v docker &>/dev/null; then
  echo "  [FAIL] Docker not found"
  exit 1
fi

(cd "$APP_REPO" && docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" . 2>&1) | tail -3
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  echo "  [FAIL] Docker build failed"
  exit 1
fi
echo "  [PASS] Docker build: ${IMAGE_NAME}:${IMAGE_TAG}"

# -------------------------------------------------------------------------
# Step 2: Push to ACR
# -------------------------------------------------------------------------
echo ""
echo "--- Step 2: Push to ACR ---"
az acr login --name "$ACR" 2>&1 | tail -1

docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "$FULL_IMAGE"
docker push "$FULL_IMAGE" 2>&1 | tail -3
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  echo "  [FAIL] Docker push failed"
  exit 1
fi
echo "  [PASS] Pushed: ${FULL_IMAGE}"

# -------------------------------------------------------------------------
# Step 3: Deploy Bridge Function
# -------------------------------------------------------------------------
echo ""
echo "--- Step 3: Deploy Bridge Function ---"

BRIDGE_DIR="${INFRA_DIR}/functions/purview-bridge"
DEPLOY_ZIP="${BRIDGE_DIR}/deploy-prod.zip"

# Build zip from publish_v3 if it doesn't exist or is older
PUBLISH_DIR="${BRIDGE_DIR}/publish_v3"
if [[ -d "$PUBLISH_DIR" ]]; then
  echo "  Building deployment zip from publish_v3..."
  python -c "
import zipfile, os
src = '${PUBLISH_DIR}'
dst = '${DEPLOY_ZIP}'
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        for d in dirs:
            dp = os.path.join(root, d)
            zf.write(dp, os.path.relpath(dp, src) + '/')
        for f in files:
            fp = os.path.join(root, f)
            zf.write(fp, os.path.relpath(fp, src))
print(f'  Created: {dst}')
" 2>&1
fi

if [[ ! -f "$DEPLOY_ZIP" ]]; then
  echo "  [FAIL] No deployment zip found at ${DEPLOY_ZIP}"
  exit 1
fi

az functionapp deployment source config-zip \
  --name "$FUNC_NAME" \
  -g "$RESOURCE_GROUP" \
  --src "$DEPLOY_ZIP" \
  --timeout 300 2>&1 | tail -3

DEPLOY_STATUS=$?
if [[ $DEPLOY_STATUS -ne 0 ]]; then
  echo "  [FAIL] Function deployment failed"
  exit 1
fi
echo "  [PASS] Bridge Function deployed"

# Verify
FUNC_COUNT=$(az functionapp function list --name "$FUNC_NAME" -g "$RESOURCE_GROUP" --query "length([])" -o tsv 2>/dev/null)
echo "  Functions deployed: ${FUNC_COUNT:-0}"

echo ""
echo "=== Build & Push Complete ==="
