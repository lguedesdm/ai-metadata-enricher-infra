#!/usr/bin/env bash
# =============================================================================
# AIME Environment Validation Script
# =============================================================================
# Validates the real state of Azure resources against expected AIME infrastructure.
# 100% READ-ONLY — never modifies any Azure resource.
#
# Usage:
#   ./scripts/validate-environment.sh --environment dev [--project-name ai-metadata] [--skip-purview] [--verbose]
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
ENVIRONMENT=""
PROJECT="ai-metadata"
SKIP_PURVIEW=false
VERBOSE=false

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      ENVIRONMENT="$2"; shift 2 ;;
    --project-name)
      PROJECT="$2"; shift 2 ;;
    --skip-purview)
      SKIP_PURVIEW=true; shift ;;
    --verbose)
      VERBOSE=true; shift ;;
    -h|--help)
      echo "Usage: $0 --environment <env> [--project-name <name>] [--skip-purview] [--verbose]"
      exit 0 ;;
    *)
      echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENVIRONMENT" ]]; then
  echo "ERROR: --environment is required"
  echo "Usage: $0 --environment <env> [--project-name <name>] [--skip-purview] [--verbose]"
  exit 1
fi

# -----------------------------------------------------------------------------
# Derive Resource Names
# -----------------------------------------------------------------------------
PREFIX="${PROJECT}-${ENVIRONMENT}"
PREFIX_NO_DASH="${PROJECT//-/}${ENVIRONMENT//-/}"

RG="rg-${PREFIX}"
COSMOS="cosmos-${PREFIX}"
SBUS="${PREFIX}-sbus"
EHNS="${PREFIX}-eh"
SEARCH="${PREFIX}-search"
OAI="oai-${PREFIX}"
ACR="cr${PREFIX_NO_DASH:0:20}"
CA="ca-orchestrator-${PREFIX}"
CAE="cae-${PREFIX}"
FUNC="func-bridge-${PREFIX}"
LOG="log-${PREFIX}"
APPI="appi-${PREFIX}"
PURVIEW="purview-${PREFIX}"

# -----------------------------------------------------------------------------
# Counters & State
# -----------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
FAILURES=()

# Resource existence flags
RG_OK=false
COSMOS_OK=false
SBUS_OK=false
EHNS_OK=false
SEARCH_OK=false
OAI_OK=false
ACR_OK=false
CA_OK=false
FUNC_OK=false
LOG_OK=false
PURVIEW_OK=false

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
check_pass() {
  local id="$1"; local msg="$2"
  echo "  [PASS] ${id}  ${msg}"
  PASS=$((PASS + 1))
}

check_fail() {
  local id="$1"; local msg="$2"
  echo "  [FAIL] ${id}  ${msg}"
  FAIL=$((FAIL + 1))
  FAILURES+=("${id}: ${msg}")
}

check_skip() {
  local id="$1"; local msg="$2"
  echo "  [SKIP] ${id}  ${msg}"
  SKIP=$((SKIP + 1))
}

verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "  [DEBUG] $*"
  fi
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
echo ""
echo "=== AIME Environment Validation: ${ENVIRONMENT} ==="
echo "  Project: ${PROJECT}  |  Resource Group: ${RG}"
echo ""

if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) not found. Install from https://aka.ms/installazurecli"
  exit 1
fi

if ! az account show &>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run 'az login' first."
  exit 1
fi

SUBSCRIPTION=$(az account show --query name -o tsv 2>/dev/null)
echo "  Subscription: ${SUBSCRIPTION}"
echo ""

# =============================================================================
# RESOURCE EXISTENCE (11 checks)
# =============================================================================
echo "--- Resource Existence (11 checks) ---"

# RES-001: Resource Group
STATE=$(az group show --name "$RG" --query properties.provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-001" "Resource Group ${RG} (${STATE})"
  RG_OK=true
else
  check_fail "RES-001" "Resource Group ${RG} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-002: Cosmos DB
STATE=$(az cosmosdb show --name "$COSMOS" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-002" "Cosmos DB ${COSMOS} (${STATE})"
  COSMOS_OK=true
else
  check_fail "RES-002" "Cosmos DB ${COSMOS} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-003: Service Bus
STATE=$(az servicebus namespace show --name "$SBUS" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-003" "Service Bus ${SBUS} (${STATE})"
  SBUS_OK=true
else
  check_fail "RES-003" "Service Bus ${SBUS} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-004: Event Hub Namespace
STATE=$(az eventhubs namespace show --name "$EHNS" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-004" "Event Hub NS ${EHNS} (${STATE})"
  EHNS_OK=true
else
  check_fail "RES-004" "Event Hub NS ${EHNS} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-005: Azure AI Search
STATE=$(az search service show --name "$SEARCH" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
STATE=$(echo "$STATE" | tr '[:lower:]' '[:upper:]')
if [[ "$STATE" == "SUCCEEDED" ]]; then
  check_pass "RES-005" "AI Search ${SEARCH} (${STATE})"
  SEARCH_OK=true
else
  check_fail "RES-005" "AI Search ${SEARCH} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-006: Azure OpenAI
STATE=$(az cognitiveservices account show --name "$OAI" -g "$RG" --query properties.provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-006" "OpenAI ${OAI} (${STATE})"
  OAI_OK=true
else
  check_fail "RES-006" "OpenAI ${OAI} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-007: Container Registry
STATE=$(az acr show --name "$ACR" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-007" "ACR ${ACR} (${STATE})"
  ACR_OK=true
else
  check_fail "RES-007" "ACR ${ACR} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-008: Container App
STATE=$(az containerapp show --name "$CA" -g "$RG" --query properties.provisioningState -o tsv 2>/dev/null)
# Check if revision is healthy (provisioning state may be stale from failed deploy)
REVISION_HEALTH=$(az containerapp revision list --name "$CA" -g "$RG" --query "[0].properties.healthState" -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" || "$REVISION_HEALTH" == "Healthy" ]]; then
  check_pass "RES-008" "Container App ${CA} (state: ${STATE:-N/A}, revision: ${REVISION_HEALTH:-N/A})"
  CA_OK=true
else
  check_fail "RES-008" "Container App ${CA} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-009: Function App
# Flex Consumption (FC1) functions return state=null; fall back to checking existence
STATE=$(az functionapp show --name "$FUNC" -g "$RG" --query state -o tsv 2>/dev/null)
FUNC_EXISTS=$(az functionapp show --name "$FUNC" -g "$RG" --query name -o tsv 2>/dev/null)
if [[ "$STATE" == "Running" || ( -n "$FUNC_EXISTS" && ( -z "$STATE" || "$STATE" == "None" ) ) ]]; then
  check_pass "RES-009" "Function App ${FUNC} (${STATE:-FlexConsumption})"
  FUNC_OK=true
else
  check_fail "RES-009" "Function App ${FUNC} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-010: Log Analytics Workspace
STATE=$(az monitor log-analytics workspace show --workspace-name "$LOG" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
if [[ "$STATE" == "Succeeded" ]]; then
  check_pass "RES-010" "Log Analytics ${LOG} (${STATE})"
  LOG_OK=true
else
  check_fail "RES-010" "Log Analytics ${LOG} NOT FOUND or state: ${STATE:-N/A}"
fi

# RES-011: Purview
if [[ "$SKIP_PURVIEW" == "true" ]]; then
  check_skip "RES-011" "Purview ${PURVIEW} (--skip-purview)"
else
  STATE=$(az purview account show --name "$PURVIEW" -g "$RG" --query provisioningState -o tsv 2>/dev/null)
  if [[ "$STATE" == "Succeeded" ]]; then
    check_pass "RES-011" "Purview ${PURVIEW} (${STATE})"
    PURVIEW_OK=true
  else
    check_fail "RES-011" "Purview ${PURVIEW} NOT FOUND or state: ${STATE:-N/A}"
  fi
fi

echo ""

# =============================================================================
# RBAC ASSIGNMENTS (8 checks)
# =============================================================================
echo "--- RBAC Assignments (8 checks) ---"

ORCH_PRINCIPAL=""
BRIDGE_PRINCIPAL=""

if [[ "$CA_OK" == "true" ]]; then
  ORCH_PRINCIPAL=$(az containerapp show --name "$CA" -g "$RG" --query identity.principalId -o tsv 2>/dev/null)
fi
if [[ "$FUNC_OK" == "true" ]]; then
  BRIDGE_PRINCIPAL=$(az functionapp identity show --name "$FUNC" -g "$RG" --query principalId -o tsv 2>/dev/null)
fi

verbose "Orchestrator principal: ${ORCH_PRINCIPAL:-EMPTY}"
verbose "Bridge principal: ${BRIDGE_PRINCIPAL:-EMPTY}"

# Helper: check Cosmos data-plane RBAC
check_cosmos_rbac() {
  local id="$1" label="$2" principal="$3" role_def_id="$4"
  if [[ -z "$principal" ]]; then
    check_skip "$id" "${label} — principal ID unknown"
    return
  fi
  if [[ "$COSMOS_OK" != "true" ]]; then
    check_skip "$id" "${label} — Cosmos not available"
    return
  fi
  local result
  result=$(az cosmosdb sql role assignment list --account-name "$COSMOS" -g "$RG" \
    --query "[?principalId=='${principal}' && contains(roleDefinitionId,'${role_def_id}')]" -o tsv 2>/dev/null)
  if [[ -n "$result" ]]; then
    check_pass "$id" "${label}"
  else
    check_fail "$id" "${label} — role assignment NOT FOUND"
  fi
}

# Helper: check ARM RBAC
check_arm_rbac() {
  local id="$1" label="$2" principal="$3" role_id="$4" scope="$5"
  if [[ -z "$principal" ]]; then
    check_skip "$id" "${label} — principal ID unknown"
    return
  fi
  if [[ -z "$scope" ]]; then
    check_skip "$id" "${label} — resource not available"
    return
  fi
  local result
  # Extract resource name from scope for case-insensitive matching
  # (Azure returns 'resourcegroups' lowercase but az CLI returns 'resourceGroups')
  local resource_name
  resource_name=$(basename "$scope")
  result=$(az role assignment list --assignee "$principal" --all \
    --query "[?contains(roleDefinitionId,'${role_id}') && contains(scope,'${resource_name}')].id" -o tsv 2>/dev/null)
  if [[ -n "$result" ]]; then
    check_pass "$id" "${label}"
  else
    check_fail "$id" "${label} — role assignment NOT FOUND"
  fi
}

# Get resource IDs for scoping
COSMOS_ID=""
SBUS_ID=""
SEARCH_ID=""
OAI_ID=""
ACR_ID=""

if [[ "$COSMOS_OK" == "true" ]]; then
  COSMOS_ID=$(az cosmosdb show --name "$COSMOS" -g "$RG" --query id -o tsv 2>/dev/null)
fi
if [[ "$SBUS_OK" == "true" ]]; then
  SBUS_ID=$(az servicebus namespace show --name "$SBUS" -g "$RG" --query id -o tsv 2>/dev/null)
fi
if [[ "$SEARCH_OK" == "true" ]]; then
  SEARCH_ID=$(az search service show --name "$SEARCH" -g "$RG" --query id -o tsv 2>/dev/null)
fi
if [[ "$OAI_OK" == "true" ]]; then
  OAI_ID=$(az cognitiveservices account show --name "$OAI" -g "$RG" --query id -o tsv 2>/dev/null)
fi
if [[ "$ACR_OK" == "true" ]]; then
  ACR_ID=$(az acr show --name "$ACR" -g "$RG" --query id -o tsv 2>/dev/null)
fi

# RBAC-001: Orchestrator → Cosmos Data Contributor
check_cosmos_rbac "RBAC-001" "Orchestrator → Cosmos Data Contributor" "$ORCH_PRINCIPAL" "00000000-0000-0000-0000-000000000002"

# RBAC-002: Bridge → Cosmos Data Contributor
check_cosmos_rbac "RBAC-002" "Bridge → Cosmos Data Contributor" "$BRIDGE_PRINCIPAL" "00000000-0000-0000-0000-000000000002"

# RBAC-003: Orchestrator → SB Data Receiver
check_arm_rbac "RBAC-003" "Orchestrator → SB Data Receiver" "$ORCH_PRINCIPAL" "4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0" "$SBUS_ID"

# RBAC-004: Bridge → SB Data Sender
check_arm_rbac "RBAC-004" "Bridge → SB Data Sender" "$BRIDGE_PRINCIPAL" "69a216fc-b8fb-44d8-bc22-1f3c2cd27a39" "$SBUS_ID"

# RBAC-005: Bridge → SB Data Receiver
check_arm_rbac "RBAC-005" "Bridge → SB Data Receiver" "$BRIDGE_PRINCIPAL" "4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0" "$SBUS_ID"

# RBAC-006: Orchestrator → Search Index Data Reader
check_arm_rbac "RBAC-006" "Orchestrator → Search Index Data Reader" "$ORCH_PRINCIPAL" "1407120a-92aa-4202-b7e9-c0e197c71c8f" "$SEARCH_ID"

# RBAC-007: Orchestrator → OpenAI User
check_arm_rbac "RBAC-007" "Orchestrator → OpenAI User" "$ORCH_PRINCIPAL" "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd" "$OAI_ID"

# RBAC-008: Orchestrator → AcrPull
check_arm_rbac "RBAC-008" "Orchestrator → AcrPull" "$ORCH_PRINCIPAL" "7f951dda-4ed3-4680-a7ca-43fe172d538d" "$ACR_ID"

echo ""

# =============================================================================
# PURVIEW DATA-PLANE (3 checks)
# =============================================================================
echo "--- Purview Data-Plane (4 checks) ---"

if [[ "$PURVIEW_OK" != "true" ]]; then
  check_skip "PV-001" "Purview custom type AI_Enrichment — Purview not available"
  check_skip "PV-002" "Orchestrator in data-curator policy — Purview not available"
  check_skip "PV-003" "Bridge in data-curator policy — Purview not available"
  check_skip "PV-004" "Bridge in purview-reader policy — Purview not available"
else
  PV_TOKEN=$(az account get-access-token --resource "https://purview.azure.net" --query accessToken -o tsv 2>/dev/null)
  PV_ENDPOINT="https://${PURVIEW}.purview.azure.com"

  if [[ -z "$PV_TOKEN" ]]; then
    check_skip "PV-001" "Purview custom type — could not obtain token"
    check_skip "PV-002" "Orchestrator in data-curator — could not obtain token"
    check_skip "PV-003" "Bridge in data-curator — could not obtain token"
    check_skip "PV-004" "Bridge in purview-reader — could not obtain token"
  else
    # PV-001: Custom type AI_Enrichment
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${PV_TOKEN}" \
      "${PV_ENDPOINT}/datamap/api/atlas/v2/types/typedef/name/AI_Enrichment" 2>/dev/null)
    if [[ "$HTTP_CODE" == "200" ]]; then
      check_pass "PV-001" "Purview custom type AI_Enrichment exists"
    else
      check_fail "PV-001" "Purview custom type AI_Enrichment NOT FOUND (HTTP ${HTTP_CODE})"
    fi

    # PV-002 & PV-003: Metadata policies
    POLICIES_JSON=$(curl -s \
      -H "Authorization: Bearer ${PV_TOKEN}" \
      "${PV_ENDPOINT}/policystore/metadataPolicies?api-version=2021-07-01" 2>/dev/null)

    if [[ -n "$POLICIES_JSON" ]]; then
      # PV-002: Orchestrator MI in data-curator
      if [[ -n "$ORCH_PRINCIPAL" ]]; then
        ORCH_IN_POLICY=$(echo "$POLICIES_JSON" | python -c "
import sys, json
data = json.load(sys.stdin)
found = False
for policy in data.get('values', []):
    for rule in policy.get('properties', {}).get('attributeRules', []):
        if 'data-curator' in rule.get('id', ''):
            members = rule.get('dnfCondition', [])
            for group in members:
                for cond in group:
                    if '${ORCH_PRINCIPAL}' in str(cond.get('attributeValueIncludedIn', [])):
                        found = True
print('true' if found else 'false')
" 2>/dev/null)
        if [[ "$ORCH_IN_POLICY" == "true" ]]; then
          check_pass "PV-002" "Orchestrator MI in data-curator policy"
        else
          check_fail "PV-002" "Orchestrator MI NOT in data-curator policy"
        fi
      else
        check_skip "PV-002" "Orchestrator in data-curator — principal ID unknown"
      fi

      # PV-003: Bridge MI in data-curator
      if [[ -n "$BRIDGE_PRINCIPAL" ]]; then
        BRIDGE_IN_POLICY=$(echo "$POLICIES_JSON" | python -c "
import sys, json
data = json.load(sys.stdin)
found = False
for policy in data.get('values', []):
    for rule in policy.get('properties', {}).get('attributeRules', []):
        if 'data-curator' in rule.get('id', ''):
            members = rule.get('dnfCondition', [])
            for group in members:
                for cond in group:
                    if '${BRIDGE_PRINCIPAL}' in str(cond.get('attributeValueIncludedIn', [])):
                        found = True
print('true' if found else 'false')
" 2>/dev/null)
        if [[ "$BRIDGE_IN_POLICY" == "true" ]]; then
          check_pass "PV-003" "Bridge MI in data-curator policy"
        else
          check_fail "PV-003" "Bridge MI NOT in data-curator policy"
        fi
      else
        check_skip "PV-003" "Bridge in data-curator — principal ID unknown"
      fi

      # PV-004: Bridge MI in purview-reader
      if [[ -n "$BRIDGE_PRINCIPAL" ]]; then
        BRIDGE_IN_READER=$(echo "$POLICIES_JSON" | python -c "
import sys, json
data = json.load(sys.stdin)
found = False
for policy in data.get('values', []):
    for rule in policy.get('properties', {}).get('attributeRules', []):
        if 'purview-reader' in rule.get('id', ''):
            members = rule.get('dnfCondition', [])
            for group in members:
                for cond in group:
                    if '${BRIDGE_PRINCIPAL}' in str(cond.get('attributeValueIncludedIn', [])):
                        found = True
print('true' if found else 'false')
" 2>/dev/null)
        if [[ "$BRIDGE_IN_READER" == "true" ]]; then
          check_pass "PV-004" "Bridge MI in purview-reader policy"
        else
          check_fail "PV-004" "Bridge MI NOT in purview-reader policy"
        fi
      else
        check_skip "PV-004" "Bridge in purview-reader — principal ID unknown"
      fi
    else
      check_fail "PV-002" "Orchestrator in data-curator — failed to fetch policies"
      check_fail "PV-003" "Bridge in data-curator — failed to fetch policies"
      check_fail "PV-004" "Bridge in purview-reader — failed to fetch policies"
    fi
  fi
fi

echo ""

# =============================================================================
# DATA-PLANE CONFIG (5 checks)
# =============================================================================
echo "--- Data-Plane Config (5 checks) ---"

# CFG-001: Cosmos containers (state + audit)
if [[ "$COSMOS_OK" == "true" ]]; then
  STATE_CONTAINER=$(az cosmosdb sql container show --account-name "$COSMOS" -g "$RG" \
    --database-name metadata_enricher --name state --query name -o tsv 2>/dev/null)
  AUDIT_CONTAINER=$(az cosmosdb sql container show --account-name "$COSMOS" -g "$RG" \
    --database-name metadata_enricher --name audit --query name -o tsv 2>/dev/null)
  if [[ "$STATE_CONTAINER" == "state" && "$AUDIT_CONTAINER" == "audit" ]]; then
    check_pass "CFG-001" "Cosmos containers: state + audit exist"
  else
    check_fail "CFG-001" "Cosmos containers missing (state=${STATE_CONTAINER:-N/A}, audit=${AUDIT_CONTAINER:-N/A})"
  fi
else
  check_skip "CFG-001" "Cosmos containers — Cosmos not available"
fi

# CFG-002: Service Bus queues
if [[ "$SBUS_OK" == "true" ]]; then
  Q1_STATUS=$(az servicebus queue show --namespace-name "$SBUS" -g "$RG" --name enrichment-requests --query status -o tsv 2>/dev/null)
  Q2_STATUS=$(az servicebus queue show --namespace-name "$SBUS" -g "$RG" --name purview-events --query status -o tsv 2>/dev/null)
  if [[ "$Q1_STATUS" == "Active" && "$Q2_STATUS" == "Active" ]]; then
    check_pass "CFG-002" "SB queues: enrichment-requests + purview-events (Active)"
  else
    check_fail "CFG-002" "SB queues not Active (enrichment-requests=${Q1_STATUS:-N/A}, purview-events=${Q2_STATUS:-N/A})"
  fi
else
  check_skip "CFG-002" "SB queues — Service Bus not available"
fi

# CFG-003: Event Hub + consumer group
if [[ "$EHNS_OK" == "true" ]]; then
  EH_STATUS=$(az eventhubs eventhub show --namespace-name "$EHNS" -g "$RG" --name purview-diagnostics --query status -o tsv 2>/dev/null)
  CG_EXISTS=$(az eventhubs eventhub consumer-group show --namespace-name "$EHNS" -g "$RG" \
    --eventhub-name purview-diagnostics --name bridge-function --query name -o tsv 2>/dev/null)
  if [[ "$EH_STATUS" == "Active" && "$CG_EXISTS" == "bridge-function" ]]; then
    check_pass "CFG-003" "Event Hub purview-diagnostics + consumer group bridge-function"
  else
    check_fail "CFG-003" "Event Hub config (hub=${EH_STATUS:-N/A}, consumer-group=${CG_EXISTS:-N/A})"
  fi
else
  check_skip "CFG-003" "Event Hub — namespace not available"
fi

# CFG-004: Purview diagnostic settings
if [[ "$PURVIEW_OK" == "true" ]]; then
  DIAG_NAME=$(az monitor diagnostic-settings list \
    --resource "$PURVIEW" --resource-group "$RG" --resource-type Microsoft.Purview/accounts \
    --query "[?name=='purview-to-eventhub'].name" -o tsv 2>/dev/null)
  if [[ "$DIAG_NAME" == "purview-to-eventhub" ]]; then
    check_pass "CFG-004" "Purview diagnostic setting purview-to-eventhub exists"
  else
    check_fail "CFG-004" "Purview diagnostic setting purview-to-eventhub NOT FOUND"
  fi
elif [[ "$SKIP_PURVIEW" == "true" ]]; then
  check_skip "CFG-004" "Purview diagnostic settings — --skip-purview"
else
  check_skip "CFG-004" "Purview diagnostic settings — Purview not available"
fi

# CFG-005: Search index exists
if [[ "$SEARCH_OK" == "true" ]]; then
  SEARCH_TOKEN=$(az account get-access-token --resource "https://search.azure.com" --query accessToken -o tsv 2>/dev/null)
  if [[ -n "$SEARCH_TOKEN" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${SEARCH_TOKEN}" \
      "https://${SEARCH}.search.windows.net/indexes/metadata-context-index?api-version=2024-07-01" 2>/dev/null)
    if [[ "$HTTP_CODE" == "200" ]]; then
      check_pass "CFG-005" "Search index metadata-context-index exists"
    else
      check_fail "CFG-005" "Search index metadata-context-index NOT FOUND (HTTP ${HTTP_CODE})"
    fi
  else
    check_skip "CFG-005" "Search index — could not obtain token"
  fi
else
  check_skip "CFG-005" "Search index — Search service not available"
fi

echo ""

# =============================================================================
# APP CONFIG (3 checks)
# =============================================================================
echo "--- App Config (3 checks) ---"

# APP-001: Container App env vars
if [[ "$CA_OK" == "true" ]]; then
  CA_ENV_JSON=$(az containerapp show --name "$CA" -g "$RG" \
    --query "properties.template.containers[0].env" -o json 2>/dev/null)

  if [[ -n "$CA_ENV_JSON" && "$CA_ENV_JSON" != "null" ]]; then
    CA_ENV_COUNT=$(echo "$CA_ENV_JSON" | python -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    verbose "Container App env var count: ${CA_ENV_COUNT}"

    # Check frozen values
    CA_FROZEN_OK=true
    CA_FROZEN_ERRORS=""
    declare -A CA_FROZEN=(
      ["SERVICE_BUS_QUEUE_NAME"]="enrichment-requests"
      ["COSMOS_DATABASE_NAME"]="metadata_enricher"
      ["COSMOS_STATE_CONTAINER"]="state"
      ["COSMOS_AUDIT_CONTAINER"]="audit"
      ["AZURE_SEARCH_INDEX_NAME"]="metadata-context-index"
      ["AZURE_SEARCH_SEMANTIC_CONFIG"]="default-semantic-config"
      ["AZURE_OPENAI_API_VERSION"]="2024-06-01"
    )
    for key in "${!CA_FROZEN[@]}"; do
      expected="${CA_FROZEN[$key]}"
      actual=$(echo "$CA_ENV_JSON" | python -c "
import sys, json
envs = json.load(sys.stdin)
for e in envs:
    if e.get('name') == '${key}':
        print(e.get('value', ''))
        break
" 2>/dev/null)
      if [[ "$actual" != "$expected" ]]; then
        CA_FROZEN_OK=false
        CA_FROZEN_ERRORS="${CA_FROZEN_ERRORS} ${key}=${actual:-MISSING}(expected ${expected});"
      fi
    done

    if [[ "$CA_FROZEN_OK" == "true" && "${CA_ENV_COUNT:-0}" -ge 15 ]]; then
      check_pass "APP-001" "Container App: ${CA_ENV_COUNT} env vars, 7 frozen values correct"
    else
      local_msg="Container App config issues:"
      if [[ "${CA_ENV_COUNT:-0}" -lt 15 ]]; then
        local_msg="${local_msg} only ${CA_ENV_COUNT}/15 env vars;"
      fi
      if [[ "$CA_FROZEN_OK" != "true" ]]; then
        local_msg="${local_msg}${CA_FROZEN_ERRORS}"
      fi
      check_fail "APP-001" "$local_msg"
    fi
  else
    check_fail "APP-001" "Container App env vars not found"
  fi
else
  check_skip "APP-001" "Container App env vars — Container App not available"
fi

# APP-002: Function App settings
if [[ "$FUNC_OK" == "true" ]]; then
  FUNC_SETTINGS=$(az functionapp config appsettings list --name "$FUNC" -g "$RG" -o json 2>/dev/null)

  if [[ -n "$FUNC_SETTINGS" && "$FUNC_SETTINGS" != "null" ]]; then
    FUNC_COUNT=$(echo "$FUNC_SETTINGS" | python -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    verbose "Function App settings count: ${FUNC_COUNT}"

    FUNC_FROZEN_OK=true
    FUNC_FROZEN_ERRORS=""
    declare -A FUNC_FROZEN=(
      ["FUNCTIONS_EXTENSION_VERSION"]="~4"
      ["EventHubName"]="purview-diagnostics"
      ["ConsumerGroup"]="bridge-function"
      ["ServiceBusQueueName"]="purview-events"
      ["PurviewEventsQueueName"]="purview-events"
      ["EnrichmentRequestsQueueName"]="enrichment-requests"
      ["CosmosDatabaseName"]="metadata_enricher"
      ["CosmosStateContainer"]="state"
      ["CosmosAuditContainer"]="audit"
    )
    for key in "${!FUNC_FROZEN[@]}"; do
      expected="${FUNC_FROZEN[$key]}"
      actual=$(echo "$FUNC_SETTINGS" | python -c "
import sys, json
settings = json.load(sys.stdin)
for s in settings:
    if s.get('name') == '${key}':
        print(s.get('value', ''))
        break
" 2>/dev/null)
      if [[ "$actual" != "$expected" ]]; then
        FUNC_FROZEN_OK=false
        FUNC_FROZEN_ERRORS="${FUNC_FROZEN_ERRORS} ${key}=${actual:-MISSING}(expected ${expected});"
      fi
    done

    if [[ "$FUNC_FROZEN_OK" == "true" && "${FUNC_COUNT:-0}" -ge 14 ]]; then
      check_pass "APP-002" "Function App: ${FUNC_COUNT} settings, 9 frozen values correct"
    else
      local_msg="Function App config issues:"
      if [[ "${FUNC_COUNT:-0}" -lt 14 ]]; then
        local_msg="${local_msg} only ${FUNC_COUNT}/14 settings;"
      fi
      if [[ "$FUNC_FROZEN_OK" != "true" ]]; then
        local_msg="${local_msg}${FUNC_FROZEN_ERRORS}"
      fi
      check_fail "APP-002" "$local_msg"
    fi
  else
    check_fail "APP-002" "Function App settings not found"
  fi
else
  check_skip "APP-002" "Function App settings — Function App not available"
fi

# APP-003: Container image is not placeholder
if [[ "$CA_OK" == "true" ]]; then
  CA_IMAGE=$(az containerapp show --name "$CA" -g "$RG" \
    --query "properties.template.containers[0].image" -o tsv 2>/dev/null)
  if [[ "$CA_IMAGE" == "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" ]]; then
    check_fail "APP-003" "Container image is still placeholder: ${CA_IMAGE}"
  elif [[ -n "$CA_IMAGE" ]]; then
    check_pass "APP-003" "Container image: ${CA_IMAGE}"
  else
    check_fail "APP-003" "Container image not found"
  fi
else
  check_skip "APP-003" "Container image — Container App not available"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "--- Summary ---"
echo "  PASS: ${PASS}  FAIL: ${FAIL}  SKIP: ${SKIP}"
echo ""

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "  FAILED checks:"
  for f in "${FAILURES[@]}"; do
    echo "    ${f}"
  done
  echo ""
fi

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
else
  exit 0
fi
