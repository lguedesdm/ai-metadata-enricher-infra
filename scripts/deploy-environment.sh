#!/usr/bin/env bash
# =============================================================================
# deploy-environment.sh — AIME Full Environment Deployment
# =============================================================================
# Orchestrates the complete deployment of an AIME environment from zero.
# Handles all 9 phases: Bicep, Purview, Docker, Functions, RBAC, validation.
#
# This script ONLY CREATES — it never deletes resources.
# It is IDEMPOTENT — safe to re-run on an existing environment.
#
# Usage:
#   ./scripts/deploy-environment.sh \
#     --environment prod \
#     --subscription-id <sub-id> \
#     --app-repo-path ../ai-metadata-enricher \
#     [--project-name ai-metadata] \
#     [--location eastus] \
#     [--storage-account <name>] \
#     [--skip-whatif] \
#     [--verbose]
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENVIRONMENT=""
SUBSCRIPTION_ID=""
PROJECT="ai-metadata"
LOCATION="eastus"
APP_REPO=""
STORAGE_SOURCE=""
SKIP_WHATIF=false
VERBOSE=false

# ---------------------------------------------------------------------------
# Parse Arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)      ENVIRONMENT="$2";      shift 2 ;;
    --subscription-id)  SUBSCRIPTION_ID="$2";  shift 2 ;;
    --project-name)     PROJECT="$2";          shift 2 ;;
    --location)         LOCATION="$2";         shift 2 ;;
    --app-repo-path)    APP_REPO="$2";         shift 2 ;;
    --storage-account)  STORAGE_SOURCE="$2";   shift 2 ;;
    --skip-whatif)      SKIP_WHATIF=true;       shift ;;
    --verbose)          VERBOSE=true;          shift ;;
    -h|--help)
      echo "Usage: $0 --environment <env> --subscription-id <sub> --app-repo-path <path> [options]"
      exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENVIRONMENT" || -z "$SUBSCRIPTION_ID" || -z "$APP_REPO" ]]; then
  echo "ERROR: --environment, --subscription-id, and --app-repo-path are required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Derived names
# ---------------------------------------------------------------------------
PREFIX="${PROJECT}-${ENVIRONMENT}"
PREFIX_NO_DASH="${PROJECT//-/}${ENVIRONMENT//-/}"
RG="rg-${PREFIX}"
ACR="cr${PREFIX_NO_DASH:0:20}"
CA="ca-orchestrator-${PREFIX}"
FUNC="func-bridge-${PREFIX}"
PURVIEW="purview-${PREFIX}"
PARAMS_FILE="infra/parameters.${ENVIRONMENT}.bicepparam"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
START_TIME=$(date +%s)

verbose() { [[ "$VERBOSE" == "true" ]] && echo "  [DEBUG] $*"; }

phase_header() {
  local phase="$1" desc="$2"
  echo ""
  echo "================================================================"
  echo "  Phase ${phase}: ${desc}"
  echo "================================================================"
}

elapsed() {
  local now=$(date +%s)
  local diff=$((now - START_TIME))
  local min=$((diff / 60))
  local sec=$((diff % 60))
  echo "${min}m${sec}s"
}

# ---------------------------------------------------------------------------
# GUARDRAIL: Production confirmation
# ---------------------------------------------------------------------------
if [[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "production" ]]; then
  echo ""
  echo "WARNING: You are about to deploy to PRODUCTION environment."
  echo "  Environment: ${ENVIRONMENT}"
  echo "  Subscription: ${SUBSCRIPTION_ID}"
  echo "  Resource Group: ${RG}"
  echo ""
  read -p "Type 'yes' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
echo "================================================================"
echo "  AIME Full Environment Deploy: ${ENVIRONMENT}"
echo "================================================================"
echo "  Project:      ${PROJECT}"
echo "  Location:     ${LOCATION}"
echo "  RG:           ${RG}"
echo "  Subscription: ${SUBSCRIPTION_ID}"
echo "  App Repo:     ${APP_REPO}"
echo "  Started:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"

# ==========================================================================
# Phase 1: Pre-flight Checks
# ==========================================================================
phase_header 1 "Pre-flight Checks"

# Check az CLI
if ! command -v az &>/dev/null; then
  echo "  [FAIL] Azure CLI not found"; exit 1
fi
echo "  [PASS] Azure CLI found"

# Check logged in
if ! az account show &>/dev/null; then
  echo "  [FAIL] Not logged in to Azure"; exit 1
fi
echo "  [PASS] Azure CLI authenticated"

# Set subscription
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null
CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null)
if [[ "$CURRENT_SUB" != "$SUBSCRIPTION_ID" ]]; then
  echo "  [FAIL] Could not set subscription ${SUBSCRIPTION_ID}"; exit 1
fi
echo "  [PASS] Subscription: $(az account show --query name -o tsv 2>/dev/null)"

# Check Docker
if ! command -v docker &>/dev/null; then
  echo "  [FAIL] Docker not found"; exit 1
fi
echo "  [PASS] Docker found"

# Check parameter file
if [[ ! -f "${INFRA_DIR}/${PARAMS_FILE}" ]]; then
  echo "  [FAIL] Parameter file not found: ${PARAMS_FILE}"; exit 1
fi
echo "  [PASS] Parameter file: ${PARAMS_FILE}"

# Check app repo
if [[ ! -f "${APP_REPO}/Dockerfile" ]]; then
  echo "  [FAIL] App repo Dockerfile not found: ${APP_REPO}/Dockerfile"; exit 1
fi
echo "  [PASS] App repo: ${APP_REPO}"

echo "  Pre-flight: ALL PASS ($(elapsed))"

# ==========================================================================
# Phase 2: Bicep Pass 1 (Core Resources)
# ==========================================================================
phase_header 2 "Bicep Pass 1 — Core Resources"

if [[ "$SKIP_WHATIF" != "true" ]]; then
  echo "  Running what-if preview..."
  az deployment sub what-if \
    --location "$LOCATION" \
    --template-file "${INFRA_DIR}/infra/main.bicep" \
    --parameters "${INFRA_DIR}/${PARAMS_FILE}" \
    deployCompute=false deployFunctions=false deployPurview=false \
    2>&1 | tail -5
  echo ""
fi

echo "  Deploying core resources (compute=false, functions=false, purview=false)..."
az deployment sub create \
  --name "aime-${ENVIRONMENT}-pass1-$(date +%s)" \
  --location "$LOCATION" \
  --template-file "${INFRA_DIR}/infra/main.bicep" \
  --parameters "${INFRA_DIR}/${PARAMS_FILE}" \
  deployCompute=false deployFunctions=false deployPurview=false \
  --query "properties.provisioningState" -o tsv 2>&1

PASS1_STATE=$(az deployment sub list --query "[?starts_with(name,'aime-${ENVIRONMENT}-pass1')].properties.provisioningState | [0]" -o tsv 2>/dev/null)
if [[ "$PASS1_STATE" != "Succeeded" ]]; then
  echo "  [FAIL] Bicep Pass 1 failed: ${PASS1_STATE}"
  echo "  Check: az deployment sub list --query \"[?starts_with(name,'aime-${ENVIRONMENT}-pass1')]\" -o table"
  exit 1
fi
echo "  [PASS] Bicep Pass 1 Succeeded ($(elapsed))"

# ==========================================================================
# Phase 3: Purview Account
# ==========================================================================
phase_header 3 "Purview Account"

PV_EXISTS=$(az purview account show --name "$PURVIEW" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$PV_EXISTS" == "Succeeded" ]]; then
  echo "  [PASS] Purview ${PURVIEW} already exists (Succeeded)"
else
  echo "  Creating Purview account (this takes ~10-15 min)..."
  az purview account create \
    --name "$PURVIEW" \
    --resource-group "$RG" \
    --location "$LOCATION" \
    --no-wait 2>&1 | tail -1

  # Wait for provisioning to complete
  echo "  Waiting for Purview provisioning..."
  for i in $(seq 1 30); do
    PV_STATE=$(az purview account show --name "$PURVIEW" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
    if [[ "$PV_STATE" == "Succeeded" ]]; then
      break
    fi
    verbose "Purview state: ${PV_STATE:-unknown} (attempt ${i}/30)"
    sleep 30
  done

  if [[ "$PV_STATE" != "Succeeded" ]]; then
    echo "  [FAIL] Purview provisioning timed out: ${PV_STATE}"
    exit 1
  fi
  echo "  [PASS] Purview ${PURVIEW} created ($(elapsed))"
fi

# ==========================================================================
# Phase 4: Container Image Build & Push
# ==========================================================================
phase_header 4 "Container Image"

echo "  Building Docker image..."
(cd "$APP_REPO" && docker build -t "ai-metadata-orchestrator:${ENVIRONMENT}" . 2>&1) | tail -3

echo "  Logging in to ACR ${ACR}..."
az acr login --name "$ACR" 2>&1 | tail -1

FULL_IMAGE="${ACR}.azurecr.io/ai-metadata-orchestrator:${ENVIRONMENT}"
docker tag "ai-metadata-orchestrator:${ENVIRONMENT}" "$FULL_IMAGE"

echo "  Pushing ${FULL_IMAGE}..."
docker push "$FULL_IMAGE" 2>&1 | tail -3
echo "  [PASS] Image pushed ($(elapsed))"

# ==========================================================================
# Phase 5: Bicep Pass 2 (Compute + Functions + Purview)
# ==========================================================================
phase_header 5 "Bicep Pass 2 — Full Deploy"

echo "  Deploying all resources (compute=true, functions=true, purview=true)..."
az deployment sub create \
  --name "aime-${ENVIRONMENT}-pass2-$(date +%s)" \
  --location "$LOCATION" \
  --template-file "${INFRA_DIR}/infra/main.bicep" \
  --parameters "${INFRA_DIR}/${PARAMS_FILE}" \
  --query "properties.provisioningState" -o tsv 2>&1

# Check if compute failed (AcrPull chicken-and-egg)
CA_STATE=$(az containerapp show --name "$CA" -g "$RG" --query properties.provisioningState -o tsv 2>/dev/null)
CA_HEALTH=$(az containerapp revision list --name "$CA" -g "$RG" --query "[0].properties.healthState" -o tsv 2>/dev/null)

if [[ "$CA_STATE" == "Failed" && "$CA_HEALTH" != "Healthy" ]]; then
  echo "  [WARN] Container App failed — assigning AcrPull manually and retrying..."

  # Get orchestrator MI
  ORCH_MI_PASS2=$(az containerapp show --name "$CA" -g "$RG" --query identity.principalId -o tsv 2>/dev/null)
  ACR_ID=$(az acr show --name "$ACR" -g "$RG" --query id -o tsv 2>/dev/null)

  if [[ -n "$ORCH_MI_PASS2" && -n "$ACR_ID" ]]; then
    # Assign AcrPull via REST API
    az rest --method put \
      --url "https://management.azure.com${ACR_ID}/providers/Microsoft.Authorization/roleAssignments/$(python -c 'import uuid;print(uuid.uuid4())')?api-version=2022-04-01" \
      --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d\",\"principalId\":\"${ORCH_MI_PASS2}\",\"principalType\":\"ServicePrincipal\"}}" > /dev/null 2>&1
    echo "  [INFO] AcrPull assigned to orchestrator MI"
  fi

  echo "  Waiting 60s for RBAC propagation..."
  sleep 60

  # Retry Bicep deploy
  az deployment sub create \
    --name "aime-${ENVIRONMENT}-pass3-$(date +%s)" \
    --location "$LOCATION" \
    --template-file "${INFRA_DIR}/infra/main.bicep" \
    --parameters "${INFRA_DIR}/${PARAMS_FILE}" \
    --query "properties.provisioningState" -o tsv 2>&1

  # Update CA state
  CA_HEALTH=$(az containerapp revision list --name "$CA" -g "$RG" --query "[0].properties.healthState" -o tsv 2>/dev/null)
fi

CA_HEALTH=$(az containerapp revision list --name "$CA" -g "$RG" --query "[0].properties.healthState" -o tsv 2>/dev/null)
if [[ "$CA_HEALTH" == "Healthy" ]]; then
  echo "  [PASS] Container App revision Healthy ($(elapsed))"
else
  echo "  [WARN] Container App health: ${CA_HEALTH:-unknown} — may need manual check"
fi

# ==========================================================================
# Phase 6: Bridge Function Deploy
# ==========================================================================
phase_header 6 "Bridge Function Deploy"

BRIDGE_DIR="${INFRA_DIR}/functions/purview-bridge"
DEPLOY_ZIP="${BRIDGE_DIR}/deploy-prod.zip"
PUBLISH_DIR="${BRIDGE_DIR}/publish_v3"

if [[ -d "$PUBLISH_DIR" ]]; then
  echo "  Building deployment zip..."
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
" 2>&1
fi

if [[ ! -f "$DEPLOY_ZIP" ]]; then
  echo "  [FAIL] No deployment zip found"; exit 1
fi

echo "  Deploying to ${FUNC}..."
az functionapp deployment source config-zip \
  --name "$FUNC" -g "$RG" \
  --src "$DEPLOY_ZIP" \
  --timeout 300 2>&1 | tail -3

FUNC_COUNT=$(az functionapp function list --name "$FUNC" -g "$RG" --query "length([])" -o tsv 2>/dev/null)
echo "  [PASS] Bridge deployed: ${FUNC_COUNT:-0} functions ($(elapsed))"

# ==========================================================================
# Phase 7: Purview Bootstrap
# ==========================================================================
phase_header 7 "Purview Bootstrap"

ORCH_MI=$(az containerapp show --name "$CA" -g "$RG" --query identity.principalId -o tsv 2>/dev/null)
BRIDGE_MI=$(az functionapp identity show --name "$FUNC" -g "$RG" --query principalId -o tsv 2>/dev/null)
verbose "Orchestrator MI: ${ORCH_MI}"
verbose "Bridge MI: ${BRIDGE_MI}"

if [[ -z "$ORCH_MI" || -z "$BRIDGE_MI" ]]; then
  echo "  [FAIL] Could not get MI principal IDs"
  exit 1
fi

echo "  Running bootstrap-purview.sh..."
bash "${SCRIPT_DIR}/bootstrap-purview.sh" \
  --purview-account "$PURVIEW" \
  --orchestrator-principal-id "$ORCH_MI" \
  --bridge-principal-id "$BRIDGE_MI" 2>&1 | sed 's/^/  /'

echo "  [PASS] Purview bootstrapped ($(elapsed))"

# ==========================================================================
# Phase 8: Purview Sources + Scans
# ==========================================================================
phase_header 8 "Purview Sources"

# Auto-discover storage account if not specified
if [[ -z "$STORAGE_SOURCE" ]]; then
  STORAGE_SOURCE=$(az storage account list -g "$RG" \
    --query "[?starts_with(name,'aimetadata') && !contains(name,'fnst')].name | [0]" -o tsv 2>/dev/null)
  verbose "Auto-discovered storage: ${STORAGE_SOURCE}"
fi

if [[ -n "$STORAGE_SOURCE" ]]; then
  echo "  Registering storage source: ${STORAGE_SOURCE}..."
  bash "${SCRIPT_DIR}/setup-purview-sources.sh" \
    --purview-account "$PURVIEW" \
    --environment "$ENVIRONMENT" \
    --subscription-id "$SUBSCRIPTION_ID" \
    --resource-group "$RG" \
    --storage-account "$STORAGE_SOURCE" \
    --trigger-scan 2>&1 | sed 's/^/  /'
else
  echo "  [SKIP] No storage account found for Purview source"
fi

echo "  [PASS] Purview sources configured ($(elapsed))"

# ==========================================================================
# Phase 9: Validation
# ==========================================================================
phase_header 9 "Environment Validation"

echo "  Running validate-environment.sh..."
echo ""
bash "${SCRIPT_DIR}/validate-environment.sh" --environment "$ENVIRONMENT"
VAL_EXIT=$?

# ==========================================================================
# Summary
# ==========================================================================
END_TIME=$(date +%s)
TOTAL_TIME=$(( END_TIME - START_TIME ))
TOTAL_MIN=$(( TOTAL_TIME / 60 ))
TOTAL_SEC=$(( TOTAL_TIME % 60 ))

echo ""
echo "================================================================"
echo "  DEPLOYMENT COMPLETE: ${ENVIRONMENT}"
echo "================================================================"
echo "  Total time: ${TOTAL_MIN}m${TOTAL_SEC}s"
echo "  Validation: $([ $VAL_EXIT -eq 0 ] && echo 'ALL PASS' || echo 'SOME FAILURES')"
echo ""
echo "  Next steps:"
echo "    1. Check orchestrator logs:"
echo "       az containerapp logs show --name ${CA} -g ${RG} --tail 5"
echo "    2. Run E2E test:"
echo "       ENVIRONMENT=${ENVIRONMENT} PYTHONPATH=<app-repo> python scripts/e2e_prod_validation.py"
echo "================================================================"

exit $VAL_EXIT
