#!/usr/bin/env bash
# =============================================================================
# bootstrap-purview.sh
# =============================================================================
# Automates Purview data-plane setup that cannot be done via Bicep:
#   Part A: Creates/updates the AI_Enrichment Business Metadata Type
#   Part B: Assigns Data Curator (root collection admin) to managed identities
#
# Prerequisites:
#   - Azure CLI authenticated (az login)
#   - Caller has Purview Collection Admin on the target account
#
# Usage:
#   ./scripts/bootstrap-purview.sh \
#     --purview-account purview-ai-metadata-dev \
#     --orchestrator-principal-id <id> \
#     --bridge-principal-id <id>
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PURVIEW_ACCOUNT=""
ORCHESTRATOR_PRINCIPAL_ID=""
BRIDGE_PRINCIPAL_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purview-account)       PURVIEW_ACCOUNT="$2";            shift 2 ;;
    --orchestrator-principal-id) ORCHESTRATOR_PRINCIPAL_ID="$2"; shift 2 ;;
    --bridge-principal-id)   BRIDGE_PRINCIPAL_ID="$2";        shift 2 ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 --purview-account <name> --orchestrator-principal-id <id> --bridge-principal-id <id>" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PURVIEW_ACCOUNT" || -z "$ORCHESTRATOR_PRINCIPAL_ID" || -z "$BRIDGE_PRINCIPAL_ID" ]]; then
  echo "ERROR: All three parameters are required." >&2
  echo "Usage: $0 --purview-account <name> --orchestrator-principal-id <id> --bridge-principal-id <id>" >&2
  exit 1
fi

PURVIEW_ENDPOINT="https://${PURVIEW_ACCOUNT}.purview.azure.com"

echo "=== Purview Bootstrap ==="
echo "Account:      $PURVIEW_ACCOUNT"
echo "Endpoint:     $PURVIEW_ENDPOINT"
echo ""

# ---------------------------------------------------------------------------
# Part A: Create/Update AI_Enrichment Business Metadata Type
# ---------------------------------------------------------------------------
echo "--- Part A: Business Metadata Type (AI_Enrichment) ---"

TOKEN=$(az account get-access-token --resource "https://purview.azure.net" --query accessToken -o tsv)

TYPEDEF_BODY='{
  "businessMetadataDefs": [
    {
      "category": "BUSINESS_METADATA",
      "name": "AI_Enrichment",
      "description": "AI-generated metadata enrichment. Review_status indicates approval state: PENDING = awaiting human review, APPROVED/REJECTED = steward decision recorded.",
      "typeVersion": "1.0",
      "attributeDefs": [
        {
          "name": "suggested_description",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "valuesMinCount": 0,
          "valuesMaxCount": 1,
          "isUnique": false,
          "isIndexable": true,
          "includeInNotification": false,
          "options": { "applicableEntityTypes": "[\"DataSet\"]", "maxStrLength": "5000" }
        },
        {
          "name": "confidence_score",
          "typeName": "float",
          "isOptional": true,
          "cardinality": "SINGLE",
          "valuesMinCount": 0,
          "valuesMaxCount": 1,
          "isUnique": false,
          "isIndexable": false,
          "includeInNotification": false,
          "options": { "applicableEntityTypes": "[\"DataSet\"]" }
        },
        {
          "name": "review_status",
          "typeName": "string",
          "isOptional": true,
          "cardinality": "SINGLE",
          "valuesMinCount": 0,
          "valuesMaxCount": 1,
          "isUnique": false,
          "isIndexable": true,
          "includeInNotification": false,
          "options": { "applicableEntityTypes": "[\"DataSet\"]", "maxStrLength": "50" }
        }
      ]
    }
  ]
}'

# Try POST first (for new accounts), fall back to PUT (for existing types)
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "${PURVIEW_ENDPOINT}/datamap/api/atlas/v2/types/typedefs" \
  -d "$TYPEDEF_BODY")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)

if [[ "$HTTP_CODE" -eq 200 ]]; then
  echo "OK: AI_Enrichment Business Metadata Type created (HTTP $HTTP_CODE)"
elif [[ "$HTTP_CODE" -eq 409 ]]; then
  # Type already exists — update via PUT
  echo "Type exists, updating via PUT..."
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "${PURVIEW_ENDPOINT}/datamap/api/atlas/v2/types/typedefs" \
    -d "$TYPEDEF_BODY")
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  if [[ "$HTTP_CODE" -eq 200 ]]; then
    echo "OK: AI_Enrichment Business Metadata Type updated (HTTP $HTTP_CODE)"
  else
    echo "ERROR: Failed to update AI_Enrichment (HTTP $HTTP_CODE)" >&2
    echo "$RESPONSE" | sed '$d' >&2
    exit 1
  fi
else
  echo "ERROR: Failed to create AI_Enrichment (HTTP $HTTP_CODE)" >&2
  echo "$RESPONSE" | sed '$d' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Part B: Assign Data Curator role via Metadata Policy API (data-plane)
# ---------------------------------------------------------------------------
# The az purview account add-root-collection-admin CLI command uses ARM
# control-plane and fails for guest users (#EXT#). Instead, we use the
# Purview Metadata Policy API (data-plane) which works for any Collection
# Admin. This approach directly edits the data-curator attribute rule to
# ensure both MIs have the role.
echo ""
echo "--- Part B: Data Curator RBAC (Metadata Policy API) ---"

# Discover the root collection policy ID
POLICIES_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "${PURVIEW_ENDPOINT}/policystore/metadataPolicies?api-version=2021-07-01")
POLICIES_HTTP=$(echo "$POLICIES_RESPONSE" | tail -1)
POLICIES_BODY=$(echo "$POLICIES_RESPONSE" | sed '$d')

if [[ "$POLICIES_HTTP" -ne 200 ]]; then
  echo "ERROR: Failed to list metadata policies (HTTP $POLICIES_HTTP)" >&2
  echo "$POLICIES_BODY" >&2
  exit 1
fi

POLICY_ID=$(echo "$POLICIES_BODY" | python -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('values', []):
    coll = p.get('properties', {}).get('collection', {}).get('referenceName', '')
    if coll == '${PURVIEW_ACCOUNT}':
        print(p['id'])
        break
")

if [[ -z "$POLICY_ID" ]]; then
  echo "ERROR: Could not find root collection policy for ${PURVIEW_ACCOUNT}" >&2
  exit 1
fi
echo "Root collection policy ID: $POLICY_ID"

# Fetch, update, and PUT the policy — adding both MIs to data-curator
CURRENT_POLICY=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  "${PURVIEW_ENDPOINT}/policystore/metadataPolicies/${POLICY_ID}?api-version=2021-07-01")

UPDATED_POLICY=$(echo "$CURRENT_POLICY" | python -c "
import json, sys
policy = json.load(sys.stdin)
orch_id = '${ORCHESTRATOR_PRINCIPAL_ID}'
bridge_id = '${BRIDGE_PRINCIPAL_ID}'
changed = False
for rule in policy['properties']['attributeRules']:
    if 'data-curator' in rule['id']:
        principals = rule['dnfCondition'][0][0]['attributeValueIncludedIn']
        for pid, label in [(orch_id, 'Orchestrator MI'), (bridge_id, 'Bridge MI')]:
            if pid not in principals:
                principals.append(pid)
                print(f'  Added {label} ({pid}) to data-curator', file=sys.stderr)
                changed = True
            else:
                print(f'  {label} ({pid}) already in data-curator (no-op)', file=sys.stderr)
if not changed:
    print('  All principals already present — idempotent', file=sys.stderr)
print(json.dumps(policy))
")

POLICY_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "${PURVIEW_ENDPOINT}/policystore/metadataPolicies/${POLICY_ID}?api-version=2021-07-01" \
  -d "$UPDATED_POLICY")
POLICY_HTTP=$(echo "$POLICY_RESPONSE" | tail -1)

if [[ "$POLICY_HTTP" -eq 200 ]]; then
  echo "OK: Data Curator role assignments updated (HTTP $POLICY_HTTP)"
else
  POLICY_ERR=$(echo "$POLICY_RESPONSE" | sed '$d')
  echo "ERROR: Failed to update metadata policy (HTTP $POLICY_HTTP)" >&2
  echo "$POLICY_ERR" >&2
  exit 1
fi

echo ""
echo "=== Purview Bootstrap Complete ==="
