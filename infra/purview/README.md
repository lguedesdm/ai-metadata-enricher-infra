# Microsoft Purview Integration

## Overview

This module documents the Microsoft Purview integration for the AI Metadata Enricher platform.

**Purview data-plane resources (Business Metadata, RBAC) are NOT created by Bicep.**
They must be configured manually once per environment via the Purview REST API or Purview Studio.

The Bicep module (`main.bicep`) only validates that the Purview account exists at deploy time and outputs the account name for downstream modules.

## Purpose

Microsoft Purview serves as the **governed metadata catalog**. The system interacts with Purview to:

1. **Read** entity metadata to generate AI-enriched descriptions
2. **Write** AI-generated suggestions to the `AI_Enrichment` Business Metadata attributes
3. **Poll** steward review decisions (APPROVED/REJECTED) from Purview back to Cosmos DB
4. **Preserve** human governance by never modifying the official "Description" field

---

## Business Metadata Type: `AI_Enrichment`

### Type Definition

- **Name**: `AI_Enrichment`
- **Description**: "AI-generated metadata enrichment. Review_status indicates approval state: PENDING = awaiting human review, APPROVED/REJECTED = steward decision recorded."
- **Scope**: `DataSet` entities (tables, views, columns)

### Attributes

| Attribute | Type | Indexable | Max Length | Purpose |
|-----------|------|-----------|------------|---------|
| `suggested_description` | string | yes | 5000 | AI-generated description candidate |
| `confidence_score` | float | no | — | AI confidence (0.0–1.0) |
| `review_status` | string | yes | 50 | Lifecycle state: PENDING, APPROVED, REJECTED |

### Governance Principle

**The AI MUST NEVER write to the official "Description" or "userDescription" fields.**
The orchestrator writes only to `AI_Enrichment` Business Metadata. Data stewards review suggestions and manually promote them to the official description if appropriate.

---

## Components That Interact with Purview

| Component | Repository | Interaction |
|-----------|-----------|-------------|
| **Orchestrator** (Python, Container App) | ai-metadata-enricher | Writes `suggested_description`, `confidence_score`, `review_status=PENDING` |
| **UpstreamRouterFunction** (C#, Function App) | ai-metadata-enricher-infra | Reads entity GUIDs and schema relationships |
| **ReviewStatusPollFunction** (C#, Function App) | ai-metadata-enricher-infra | Reads `review_status` from Business Metadata every hour |

---

## RBAC Requirements

Purview uses its own **collection-level RBAC**, separate from Azure ARM RBAC. The "Purview Data Curator" role cannot be assigned via Bicep — it must be configured manually.

### Principals that need Data Curator

| Principal | Purpose | How to get Principal ID |
|-----------|---------|------------------------|
| **Orchestrator MI** (Container App) | Write Business Metadata | `az containerapp show -n <name> -g <rg> --query identity.principalId` |
| **Bridge Function App MI** | Read entities for review status polling | `az functionapp identity show -n <name> -g <rg> --query principalId` |

### Assignment via CLI (run once per environment)

```bash
# Orchestrator MI
az purview account add-root-collection-admin \
  --account-name <purviewAccountName> \
  --resource-group <resourceGroup> \
  --object-id <orchestratorManagedIdentityPrincipalId>

# Bridge Function App MI
az purview account add-root-collection-admin \
  --account-name <purviewAccountName> \
  --resource-group <resourceGroup> \
  --object-id <bridgeFunctionAppManagedIdentityPrincipalId>
```

### Assignment via Purview Studio

Data Map > Collections > Root Collection > Role Assignments > Add "Data Curator" > paste MI principal ID.

---

## Manual Setup Steps (once per environment)

### 1. Provision the Purview Account

Purview accounts are provisioned via the Azure Portal or organizational governance workflows — not via Bicep. The account carries organizational policies and cannot be tied to the application lifecycle.

### 2. Create the Business Metadata Type

Via Purview REST API:

```bash
TOKEN=$(az account get-access-token --resource "https://purview.azure.net" --query accessToken -o tsv)

curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://<purviewAccountName>.purview.azure.com/datamap/api/atlas/v2/types/typedefs" \
  -d '{
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
```

### 3. Assign RBAC (Data Curator)

See [RBAC Requirements](#rbac-requirements) above.

### 4. Configure Diagnostic Settings

In the Azure Portal, on the Purview account:

Monitoring > Diagnostic Settings > Add diagnostic setting:
- **Category**: `ScanStatusLogEvent`
- **Destination**: Event Hub namespace (`{project}-{environment}-evhns`), hub `purview-diagnostics`
- **Authorization rule**: `DiagnosticsSendRule` (SAS — required by Azure platform limitation)

This enables the event pipeline: Purview scan completion > Event Hub > Bridge Function > Service Bus > Orchestrator.

---

## API Endpoints Used

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Read entity | GET | `/datamap/api/atlas/v2/entity/guid/{guid}` |
| Write Business Metadata | POST | `/datamap/api/atlas/v2/entity/guid/{guid}/businessmetadata` |
| Read type definition | GET | `/datamap/api/atlas/v2/types/typedefs` |
| Update type definition | PUT | `/datamap/api/atlas/v2/types/typedefs` |
| Search entities | POST | `/datamap/api/search/query?api-version=2023-09-01` |
| Bulk get entities | GET | `/datamap/api/atlas/v2/entity/bulk?guid=...` |

Token scope: `https://purview.azure.net/.default`
Auth: `DefaultAzureCredential()` (System-Assigned Managed Identity)

---

## Review Sync Workflow

The `ReviewStatusPollFunction` (timer trigger, every hour) synchronizes steward decisions from Purview to Cosmos DB:

```
Timer (every hour)
  -> Query Cosmos: all lifecycle records with status = "pending"
  -> For each PENDING asset:
       GET Purview entity -> read AI_Enrichment.review_status
       If APPROVED or REJECTED:
         Upsert Cosmos lifecycle record (approved/rejected)
         Write audit record (purview_sync_approved / purview_sync_rejected)
       If PENDING or absent:
         No action (steward hasn't reviewed yet)
```

The function only **reads** from Purview — it never writes to Business Metadata. This avoids the risk of overwriting steward-managed fields.

---

## Future Enhancements (Test/Prod)

- **Bootstrap script**: Automate Business Metadata Type creation and RBAC assignment per environment
- **Private Endpoints**: Secure Purview access via Private Endpoints
- **Rate limiting**: Paginate review status polling for catalogs with many PENDING assets

---

## References

- [Microsoft Purview REST API](https://learn.microsoft.com/en-us/rest/api/purview/)
- [Business Metadata in Purview](https://learn.microsoft.com/en-us/purview/concept-business-metadata)
- [Purview Collection RBAC](https://learn.microsoft.com/en-us/purview/catalog-permissions)
