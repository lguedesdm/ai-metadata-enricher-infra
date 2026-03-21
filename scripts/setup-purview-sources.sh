#!/usr/bin/env bash
# =============================================================================
# setup-purview-sources.sh
# =============================================================================
# Automates Purview data-plane configuration that cannot be done via Bicep:
#   - Register data sources (Azure SQL, Storage Account)
#   - Create scans with system rule sets
#   - Optionally trigger initial scan run
#
# Prerequisites:
#   - Azure CLI authenticated (az login)
#   - Purview account provisioned and bootstrapped (bootstrap-purview.sh)
#   - Caller has Purview Data Source Administrator on the target collection
#   - For SQL sources: Purview MI has db_datareader on target SQL database
#
# Usage:
#   ./scripts/setup-purview-sources.sh \
#     --purview-account purview-ai-metadata-prod \
#     --environment prod \
#     --subscription-id <sub-id> \
#     --resource-group rg-ai-metadata-prod \
#     [--sql-server <server-name>] \
#     [--sql-database <db-name>] \
#     [--storage-account <storage-name>] \
#     [--trigger-scan] \
#     [--verbose]
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PURVIEW_ACCOUNT=""
ENVIRONMENT=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
SQL_SERVER=""
SQL_DATABASE=""
STORAGE_ACCOUNT=""
TRIGGER_SCAN=false
VERBOSE=false

# ---------------------------------------------------------------------------
# Parse Arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purview-account)    PURVIEW_ACCOUNT="$2";   shift 2 ;;
    --environment)        ENVIRONMENT="$2";       shift 2 ;;
    --subscription-id)    SUBSCRIPTION_ID="$2";   shift 2 ;;
    --resource-group)     RESOURCE_GROUP="$2";    shift 2 ;;
    --sql-server)         SQL_SERVER="$2";        shift 2 ;;
    --sql-database)       SQL_DATABASE="$2";      shift 2 ;;
    --storage-account)    STORAGE_ACCOUNT="$2";   shift 2 ;;
    --trigger-scan)       TRIGGER_SCAN=true;      shift ;;
    --verbose)            VERBOSE=true;           shift ;;
    -h|--help)
      echo "Usage: $0 --purview-account <name> --environment <env> --subscription-id <sub> --resource-group <rg> [options]"
      echo ""
      echo "Options:"
      echo "  --sql-server <name>      Azure SQL server name (without .database.windows.net)"
      echo "  --sql-database <name>    Azure SQL database name"
      echo "  --storage-account <name> Storage account name to register as source"
      echo "  --trigger-scan           Trigger initial scan after creation"
      echo "  --verbose                Show debug output"
      exit 0 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$PURVIEW_ACCOUNT" || -z "$ENVIRONMENT" || -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" ]]; then
  echo "ERROR: --purview-account, --environment, --subscription-id, and --resource-group are required." >&2
  exit 1
fi

if [[ -z "$SQL_SERVER" && -z "$STORAGE_ACCOUNT" ]]; then
  echo "ERROR: At least one source is required (--sql-server or --storage-account)." >&2
  exit 1
fi

PV_ENDPOINT="https://${PURVIEW_ACCOUNT}.purview.azure.com"
API_VER="2022-07-01-preview"
COLLECTION_REF="$PURVIEW_ACCOUNT"

PASS=0
FAIL=0
SOURCES_CREATED=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
verbose() { [[ "$VERBOSE" == "true" ]] && echo "  [DEBUG] $*"; }

get_token() {
  az account get-access-token --resource "https://purview.azure.net" --query accessToken -o tsv 2>/dev/null
}

pv_put() {
  local path="$1" body="$2" token
  token=$(get_token)
  curl -s -w "\n%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "${PV_ENDPOINT}${path}?api-version=${API_VER}" \
    -d "$body" 2>/dev/null
}

pv_post() {
  local path="$1" body="$2" token
  token=$(get_token)
  curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "${PV_ENDPOINT}${path}?api-version=${API_VER}" \
    -d "$body" 2>/dev/null
}

pv_get() {
  local path="$1" token
  token=$(get_token)
  curl -s \
    -H "Authorization: Bearer $token" \
    "${PV_ENDPOINT}${path}?api-version=${API_VER}" 2>/dev/null
}

check_result() {
  local label="$1" response="$2"
  local http_code body
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "  [PASS] ${label} (HTTP ${http_code})"
    PASS=$((PASS + 1))
    return 0
  else
    echo "  [FAIL] ${label} (HTTP ${http_code})"
    verbose "$body"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo ""
echo "=== Purview Source Setup: ${ENVIRONMENT} ==="
echo "  Account:      ${PURVIEW_ACCOUNT}"
echo "  Endpoint:     ${PV_ENDPOINT}"
echo "  Subscription: ${SUBSCRIPTION_ID}"
echo "  RG:           ${RESOURCE_GROUP}"
echo ""

# Verify Purview is accessible
TOKEN=$(get_token)
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Could not obtain Purview token. Check az login." >&2
  exit 1
fi

EXISTING=$(pv_get "/scan/datasources")
SOURCE_COUNT=$(echo "$EXISTING" | python -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
echo "  Existing sources: ${SOURCE_COUNT:-0}"
echo ""

# =============================================================================
# STORAGE ACCOUNT SOURCE
# =============================================================================
if [[ -n "$STORAGE_ACCOUNT" ]]; then
  echo "--- Storage Account Source ---"

  SOURCE_NAME="storage-${STORAGE_ACCOUNT}"
  STORAGE_RID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"

  # Check if storage account exists
  STORAGE_EXISTS=$(az storage account show --name "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null)
  if [[ -z "$STORAGE_EXISTS" ]]; then
    echo "  [FAIL] Storage account ${STORAGE_ACCOUNT} not found in ${RESOURCE_GROUP}"
    FAIL=$((FAIL + 1))
  else
    # Get storage location
    STORAGE_LOCATION=$(az storage account show --name "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null)

    # Ensure Purview MI has Storage Blob Data Reader
    PV_MI=$(az purview account show --name "$PURVIEW_ACCOUNT" -g "$RESOURCE_GROUP" --query identity.principalId -o tsv 2>/dev/null)
    if [[ -n "$PV_MI" ]]; then
      verbose "Purview MI: ${PV_MI}"
      ROLE_CHECK=$(az role assignment list --assignee "$PV_MI" --all \
        --query "[?contains(roleDefinitionId,'2a2b9908') && contains(scope,'${STORAGE_ACCOUNT}')].id" -o tsv 2>/dev/null)
      if [[ -z "$ROLE_CHECK" ]]; then
        echo "  Assigning Storage Blob Data Reader to Purview MI..."
        az rest --method put \
          --url "https://management.azure.com${STORAGE_RID}/providers/Microsoft.Authorization/roleAssignments/$(python -c 'import uuid;print(uuid.uuid4())')?api-version=2022-04-01" \
          --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1\",\"principalId\":\"${PV_MI}\",\"principalType\":\"ServicePrincipal\"}}" > /dev/null 2>&1
        echo "  [INFO] Storage Blob Data Reader assigned — waiting 60s for propagation..."
        sleep 60
      else
        verbose "Purview MI already has Storage Blob Data Reader"
      fi
    fi

    # Register source
    BODY=$(cat <<ENDJSON
{
  "kind": "AzureStorage",
  "properties": {
    "endpoint": "https://${STORAGE_ACCOUNT}.blob.core.windows.net/",
    "resourceGroup": "${RESOURCE_GROUP}",
    "subscriptionId": "${SUBSCRIPTION_ID}",
    "location": "${STORAGE_LOCATION}",
    "resourceName": "${STORAGE_ACCOUNT}",
    "resourceId": "${STORAGE_RID}",
    "collection": {
      "referenceName": "${COLLECTION_REF}",
      "type": "CollectionReference"
    }
  }
}
ENDJSON
)
    RESULT=$(pv_put "/scan/datasources/${SOURCE_NAME}" "$BODY")
    if check_result "Register storage source: ${SOURCE_NAME}" "$RESULT"; then
      SOURCES_CREATED+=("$SOURCE_NAME")

      # Create scan
      SCAN_BODY=$(cat <<ENDJSON
{
  "kind": "AzureStorageMsi",
  "properties": {
    "scanRulesetName": "AzureStorage",
    "scanRulesetType": "System",
    "collection": {
      "referenceName": "${COLLECTION_REF}",
      "type": "CollectionReference"
    }
  }
}
ENDJSON
)
      SCAN_RESULT=$(pv_put "/scan/datasources/${SOURCE_NAME}/scans/Scan-Storage" "$SCAN_BODY")
      check_result "Create scan: Scan-Storage" "$SCAN_RESULT"

      if [[ "$TRIGGER_SCAN" == "true" ]]; then
        echo "  Triggering scan..."
        RUN_RESULT=$(pv_post "/scan/datasources/${SOURCE_NAME}/scans/Scan-Storage/run" "{}")
        check_result "Trigger scan: Scan-Storage" "$RUN_RESULT"
      fi
    fi
  fi
  echo ""
fi

# =============================================================================
# AZURE SQL DATABASE SOURCE
# =============================================================================
if [[ -n "$SQL_SERVER" ]]; then
  echo "--- Azure SQL Database Source ---"

  if [[ -z "$SQL_DATABASE" ]]; then
    echo "  [FAIL] --sql-database is required when --sql-server is specified"
    FAIL=$((FAIL + 1))
  else
    SOURCE_NAME="sql-${SQL_DATABASE}"
    SQL_FQDN="${SQL_SERVER}.database.windows.net"
    SQL_RID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Sql/servers/${SQL_SERVER}"

    # Check if SQL server exists
    SQL_EXISTS=$(az sql server show --name "$SQL_SERVER" -g "$RESOURCE_GROUP" --query name -o tsv 2>/dev/null)
    if [[ -z "$SQL_EXISTS" ]]; then
      echo "  [WARN] SQL server ${SQL_SERVER} not found in ${RESOURCE_GROUP}"
      echo "         Registering source anyway (server may be in different RG)"
    fi

    SQL_LOCATION=$(az sql server show --name "$SQL_SERVER" -g "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "eastus")

    # Register source
    BODY=$(cat <<ENDJSON
{
  "kind": "AzureSqlDatabase",
  "properties": {
    "serverEndpoint": "${SQL_FQDN}",
    "resourceGroup": "${RESOURCE_GROUP}",
    "subscriptionId": "${SUBSCRIPTION_ID}",
    "location": "${SQL_LOCATION}",
    "resourceName": "${SQL_SERVER}",
    "resourceId": "${SQL_RID}",
    "collection": {
      "referenceName": "${COLLECTION_REF}",
      "type": "CollectionReference"
    }
  }
}
ENDJSON
)
    RESULT=$(pv_put "/scan/datasources/${SOURCE_NAME}" "$BODY")
    if check_result "Register SQL source: ${SOURCE_NAME}" "$RESULT"; then
      SOURCES_CREATED+=("$SOURCE_NAME")

      # Create scan (using Managed Identity)
      SCAN_BODY=$(cat <<ENDJSON
{
  "kind": "AzureSqlDatabaseMsi",
  "properties": {
    "serverEndpoint": "${SQL_FQDN}",
    "databaseName": "${SQL_DATABASE}",
    "enableLineage": false,
    "scanRulesetName": "AzureSqlDatabase",
    "scanRulesetType": "System",
    "scanScopeType": "AutoDetect",
    "collection": {
      "referenceName": "${COLLECTION_REF}",
      "type": "CollectionReference"
    }
  }
}
ENDJSON
)
      SCAN_RESULT=$(pv_put "/scan/datasources/${SOURCE_NAME}/scans/Scan-SQL" "$SCAN_BODY")
      check_result "Create scan: Scan-SQL" "$SCAN_RESULT"

      if [[ "$TRIGGER_SCAN" == "true" ]]; then
        echo "  Triggering scan..."
        RUN_RESULT=$(pv_post "/scan/datasources/${SOURCE_NAME}/scans/Scan-SQL/run" "{}")
        check_result "Trigger scan: Scan-SQL" "$RUN_RESULT"
      fi
    fi
  fi
  echo ""
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo "--- Summary ---"
echo "  PASS: ${PASS}  FAIL: ${FAIL}"

if [[ ${#SOURCES_CREATED[@]} -gt 0 ]]; then
  echo ""
  echo "  Sources registered:"
  for s in "${SOURCES_CREATED[@]}"; do
    echo "    - ${s}"
  done
fi

# List all sources
echo ""
echo "  Current sources in Purview:"
FINAL=$(pv_get "/scan/datasources")
echo "$FINAL" | python -c "
import sys, json
data = json.load(sys.stdin)
for src in data.get('value', []):
    name = src.get('name', '?')
    kind = src.get('kind', '?')
    print(f'    - {name} ({kind})')
if not data.get('value'):
    print('    (none)')
" 2>/dev/null

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "  Some operations failed. Check output above."
  exit 1
else
  echo "  All operations succeeded."
  exit 0
fi
