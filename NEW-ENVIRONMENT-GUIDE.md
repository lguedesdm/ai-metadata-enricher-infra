# AIME - New Environment Deployment Guide

Complete step-by-step guide for deploying the AI Metadata Enricher (AIME) infrastructure and application to a new Azure environment.

**Tested and validated:** This guide was verified against a real `prod` deployment on 2026-03-20 with 30/30 infrastructure checks and 11/11 E2E tests passing.

---

## Prerequisites

- [ ] Azure CLI 2.50+ installed (`az --version`)
- [ ] Docker installed (`docker --version`)
- [ ] Python 3.11+ with project dependencies (`pip install -r requirements.txt`)
- [ ] Azure subscription with Owner or Contributor role
- [ ] Authenticated to Azure (`az login`)
- [ ] Both repositories cloned side by side:
  ```
  parent-directory/
    ai-metadata-enricher/          # Application code
    ai-metadata-enricher-infra/    # Infrastructure code
  ```

---

## Step 1: Create Parameter File

```bash
cd ai-metadata-enricher-infra/infra
cp parameters.template.bicepparam parameters.<ENV>.bicepparam
```

Edit the file and set all values. Key parameters:

| Parameter | Description | Example (prod) |
|-----------|-------------|----------------|
| `environment` | Environment name | `prod` |
| `location` | Azure region | `eastus` |
| `projectName` | Fixed project name | `ai-metadata` (do not change) |
| `storageSku` | Storage redundancy | `Standard_GRS` |
| `searchSku` | Search tier | `basic` or `standard` |
| `serviceBusSku` | Service Bus tier | `Standard` |
| `enableFreeTier` | Cosmos free tier | `false` (only 1 per subscription) |
| `deploySearchIndex` | Create search index | `true` |
| `containerImage` | Orchestrator image | `cr<project><env>.azurecr.io/ai-metadata-orchestrator:<env>` |
| `alertEmail` | Alert notifications | `team@company.com` |
| `purviewAccountName` | Purview account | `purview-ai-metadata-<env>` |
| `deployPurview` | Enable Purview module | `true` (after Purview exists) |

**Critical:** `enableFreeTier` must be `false` if another Cosmos account in the same subscription already uses free tier. Azure allows only one free-tier Cosmos account per subscription.

**Critical:** `containerImage` must reference the ACR that will be created (pattern: `cr<projectname><env>.azurecr.io/ai-metadata-orchestrator:<env>`). ACR names are alphanumeric only.

---

## Step 2: Validate Template

```bash
cd ai-metadata-enricher-infra

az deployment sub validate \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<ENV>.bicepparam \
  deployCompute=false deployFunctions=false deployPurview=false
```

Expected: `"provisioningState": "Succeeded"`

---

## Step 3: Deploy Pass 1 (Core Resources)

Deploy everything **except** compute, functions, and Purview dependency:

```bash
az deployment sub create \
  --name aime-<ENV>-pass1 \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<ENV>.bicepparam \
  deployCompute=false deployFunctions=false deployPurview=false
```

**Estimated time:** 5-10 minutes

This creates:
- Resource Group (`rg-ai-metadata-<ENV>`)
- Cosmos DB account + database + containers
- Service Bus namespace + queues
- Event Hub namespace + hub + consumer group
- Azure AI Search service + index + indexers
- Azure OpenAI account + GPT deployment
- Azure Container Registry
- Log Analytics workspace + Application Insights
- Storage account + blob containers

**Troubleshooting Pass 1:**

| Error | Cause | Fix |
|-------|-------|-----|
| `Free tier has already been applied` | Another Cosmos account uses free tier | Set `enableFreeTier = false` in parameters |
| `search-deployment Failed` | Indexers can't create without index | Set `deploySearchIndex = true` |
| `DeploymentActive` on search | Prior search deployment still running | Wait for it to complete, then retry |

---

## Step 4: Create Purview Account

Purview is NOT created by Bicep (it's provisioned separately):

```bash
az purview account create \
  --name purview-ai-metadata-<ENV> \
  --resource-group rg-ai-metadata-<ENV> \
  --location eastus
```

**Estimated time:** 10-15 minutes

Verify:
```bash
az purview account show \
  --name purview-ai-metadata-<ENV> \
  --resource-group rg-ai-metadata-<ENV> \
  --query provisioningState -o tsv
# Expected: Succeeded
```

---

## Step 5: Build and Push Container Image

```bash
cd ai-metadata-enricher

# Build
docker build -t ai-metadata-orchestrator:<ENV> .

# Login to the new ACR
az acr login --name cr<projectname><env>
# Example: az acr login --name craimetadataprod

# Tag and push
docker tag ai-metadata-orchestrator:<ENV> cr<projectname><env>.azurecr.io/ai-metadata-orchestrator:<ENV>
docker push cr<projectname><env>.azurecr.io/ai-metadata-orchestrator:<ENV>
```

Verify:
```bash
az acr repository show-tags --name cr<projectname><env> --repository ai-metadata-orchestrator
# Expected: ["<ENV>"]
```

---

## Step 6: Deploy Pass 2 (Compute + Functions + Purview)

```bash
cd ai-metadata-enricher-infra

az deployment sub create \
  --name aime-<ENV>-pass2 \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<ENV>.bicepparam
```

**Estimated time:** 5-15 minutes

**Known issue:** The Container App may show `provisioningState: Failed` on the first deploy because:
1. The AcrPull RBAC is assigned AFTER the Container App is created
2. The CA tries to pull the image before the RBAC propagates

**Fix:** Simply re-deploy (same command). On the second deploy, the RBAC is already in place and the image pull succeeds. If the CA revision shows as `Healthy`, the app is running correctly despite the cosmetic "Failed" state.

```bash
# Check if the app is actually running:
az containerapp logs show \
  --name ca-orchestrator-ai-metadata-<ENV> \
  -g rg-ai-metadata-<ENV> --tail 10
# Look for: "Connected to Service Bus queue, waiting for messages..."
```

---

## Step 7: Assign RBAC Roles

The Bicep RBAC modules may not execute if compute deployment fails on first try. Verify and assign manually if needed.

### Check existing assignments:
```bash
# Get principal IDs
ORCH_MI=$(az containerapp show --name ca-orchestrator-ai-metadata-<ENV> \
  -g rg-ai-metadata-<ENV> --query identity.principalId -o tsv)
BRIDGE_MI=$(az functionapp identity show --name func-bridge-ai-metadata-<ENV> \
  -g rg-ai-metadata-<ENV> --query principalId -o tsv)

echo "Orchestrator MI: $ORCH_MI"
echo "Bridge MI: $BRIDGE_MI"

# List roles
az role assignment list --assignee "$ORCH_MI" --all -o table
az role assignment list --assignee "$BRIDGE_MI" --all -o table
```

### Required roles:

| Principal | Role | Scope | How to assign |
|-----------|------|-------|---------------|
| Orchestrator MI | Cosmos DB Data Contributor | Cosmos account | `az cosmosdb sql role assignment create` (data-plane) |
| Bridge MI | Cosmos DB Data Contributor | Cosmos account | Same as above |
| Orchestrator MI | SB Data Receiver | SB namespace | `az rest` PUT (see below) |
| Bridge MI | SB Data Sender | SB namespace | `az rest` PUT |
| Bridge MI | SB Data Receiver | SB namespace | `az rest` PUT |
| Orchestrator MI | Search Index Data Reader | Search service | `az rest` PUT |
| Orchestrator MI | Cognitive Services OpenAI User | OpenAI account | `az rest` PUT |
| Orchestrator MI | AcrPull | Container Registry | `az rest` PUT |

### Cosmos data-plane RBAC:
```bash
MSYS_NO_PATHCONV=1 az cosmosdb sql role assignment create \
  --account-name cosmos-ai-metadata-<ENV> \
  -g rg-ai-metadata-<ENV> \
  --role-definition-id 00000000-0000-0000-0000-000000000002 \
  --principal-id $ORCH_MI \
  --scope /
```

### ARM RBAC via REST API:
```bash
# Pattern (replace SCOPE, ROLE_ID, PRINCIPAL_ID):
az rest --method put \
  --url "https://management.azure.com/<SCOPE>/providers/Microsoft.Authorization/roleAssignments/$(python -c 'import uuid;print(uuid.uuid4())')?api-version=2022-04-01" \
  --body '{"properties":{"roleDefinitionId":"/subscriptions/<SUB_ID>/providers/Microsoft.Authorization/roleDefinitions/<ROLE_ID>","principalId":"<PRINCIPAL_ID>","principalType":"ServicePrincipal"}}'
```

Role definition IDs:
- AcrPull: `7f951dda-4ed3-4680-a7ca-43fe172d538d`
- SB Data Receiver: `4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0`
- SB Data Sender: `69a216fc-b8fb-44d8-bc22-1f3c2cd27a39`
- Search Index Data Reader: `1407120a-92aa-4202-b7e9-c0e197c71c8f`
- OpenAI User: `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`

**Note:** In some environments, `az role assignment create` may fail with `MissingSubscription` error. Use `az rest` PUT as shown above instead.

---

## Step 8: Bootstrap Purview

Create the `AI_Enrichment` Business Metadata type and assign Data Curator roles:

### Part A: Create AI_Enrichment type
```bash
PV_TOKEN=$(az account get-access-token --resource "https://purview.azure.net" --query accessToken -o tsv)

curl -s -X POST \
  -H "Authorization: Bearer $PV_TOKEN" \
  -H "Content-Type: application/json" \
  "https://purview-ai-metadata-<ENV>.purview.azure.com/datamap/api/atlas/v2/types/typedefs" \
  -d '{
  "businessMetadataDefs": [{
    "category": "BUSINESS_METADATA",
    "name": "AI_Enrichment",
    "description": "AI-generated metadata enrichment.",
    "typeVersion": "1.0",
    "attributeDefs": [
      {"name":"suggested_description","typeName":"string","isOptional":true,"cardinality":"SINGLE","valuesMinCount":0,"valuesMaxCount":1,"isUnique":false,"isIndexable":true,"includeInNotification":false,"options":{"applicableEntityTypes":"[\"DataSet\"]","maxStrLength":"5000"}},
      {"name":"confidence_score","typeName":"float","isOptional":true,"cardinality":"SINGLE","valuesMinCount":0,"valuesMaxCount":1,"isUnique":false,"isIndexable":false,"includeInNotification":false,"options":{"applicableEntityTypes":"[\"DataSet\"]"}},
      {"name":"review_status","typeName":"string","isOptional":true,"cardinality":"SINGLE","valuesMinCount":0,"valuesMaxCount":1,"isUnique":false,"isIndexable":true,"includeInNotification":false,"options":{"applicableEntityTypes":"[\"DataSet\"]","maxStrLength":"50"}}
    ]
  }]
}'
```

**Note:** Use `POST` (not `PUT`) for creating types on new Purview accounts. `PUT` returns 404 for types that don't exist yet.

### Part B: Assign Data Curator role

Use the bootstrap script OR manually update via Metadata Policy API:

```bash
cd ai-metadata-enricher-infra
bash scripts/bootstrap-purview.sh \
  --purview-account purview-ai-metadata-<ENV> \
  --orchestrator-principal-id $ORCH_MI \
  --bridge-principal-id $BRIDGE_MI
```

If the bootstrap script fails on Part A (expected for new accounts), run Part A manually (POST above) then re-run the script.

### Part C: Register Data Sources and Configure Scans

Register data sources (Storage, SQL) and configure scans:

```bash
cd ai-metadata-enricher-infra

# Storage account source (auto-assigns Purview MI RBAC)
bash scripts/setup-purview-sources.sh \
  --purview-account purview-ai-metadata-<ENV> \
  --environment <ENV> \
  --subscription-id <SUB_ID> \
  --resource-group rg-ai-metadata-<ENV> \
  --storage-account <STORAGE_ACCOUNT_NAME> \
  --trigger-scan \
  --verbose

# SQL database source (requires SQL server + database to exist)
bash scripts/setup-purview-sources.sh \
  --purview-account purview-ai-metadata-<ENV> \
  --environment <ENV> \
  --subscription-id <SUB_ID> \
  --resource-group rg-ai-metadata-<ENV> \
  --sql-server <SQL_SERVER_NAME> \
  --sql-database <SQL_DATABASE_NAME> \
  --trigger-scan \
  --verbose
```

**Prerequisites for SQL scan:** The Purview system MI must have `db_datareader` on the target SQL database. Grant it via:
```sql
CREATE USER [purview-ai-metadata-<ENV>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [purview-ai-metadata-<ENV>];
```

---

## Step 9: Upload Test Data to Blob Storage

Find the storage account name:
```bash
az storage account list -g rg-ai-metadata-<ENV> --query "[?starts_with(name,'aimetadata') && !contains(name,'fnst')].name" -o tsv
```

Assign yourself Storage Blob Data Contributor:
```bash
STORAGE_ID=$(az storage account show --name <STORAGE_NAME> -g rg-ai-metadata-<ENV> --query id -o tsv)
MY_ID=$(az ad signed-in-user show --query id -o tsv)

az rest --method put \
  --url "https://management.azure.com${STORAGE_ID}/providers/Microsoft.Authorization/roleAssignments/$(python -c 'import uuid;print(uuid.uuid4())')?api-version=2022-04-01" \
  --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/<SUB_ID>/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe\",\"principalId\":\"${MY_ID}\",\"principalType\":\"User\"}}"
```

Upload test data (wait ~60s for RBAC propagation):
```bash
# Synergy mock data
az storage blob upload --account-name <STORAGE_NAME> --container-name synergy \
  --name synergy-data-dictionary.json --auth-mode login \
  --file ../ai-metadata-enricher/contracts/mocks/synergy/synergy-dev.mock.v2.json --overwrite

# Zipline mock data
az storage blob upload --account-name <STORAGE_NAME> --container-name zipline \
  --name zipline-metadata.json --auth-mode login \
  --file ../ai-metadata-enricher/contracts/mocks/zipline/zipline-dev.mock.v2.json --overwrite
```

Upload documents to the search index directly (admin key):
```bash
ADMIN_KEY=$(az search admin-key show --service-name ai-metadata-<ENV>-search \
  -g rg-ai-metadata-<ENV> --query primaryKey -o tsv)

curl -s -X POST \
  -H "api-key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  "https://ai-metadata-<ENV>-search.search.windows.net/indexes/metadata-context-index/docs/index?api-version=2024-07-01" \
  -d '{ "value": [
    {"@search.action":"upload","id":"syn-enrollment-table","sourceSystem":"synergy","source":"synergy-data-dictionary","elementType":"table","elementName":"Student Enrollment","title":"Student Enrollment","description":"Table storing student enrollment records.","content":"Synergy Student Enrollment table storing enrollment records including registration dates, campus assignments, and grade levels.","tags":["enrollment","student"],"lastUpdated":"2026-03-20T00:00:00Z"},
    {"@search.action":"upload","id":"zip-enrollment-reg","sourceSystem":"zipline","source":"zipline-metadata","elementType":"dataset","elementName":"Student Enrollment Registration","title":"Student Enrollment Registration","description":"Dataset capturing student enrollment events.","content":"Zipline Student Enrollment Registration dataset.","tags":["enrollment","registration"],"lastUpdated":"2026-03-20T00:00:00Z"}
  ]}'
```

---

## Step 10: Validate Environment

Run the 30-point infrastructure validation:

```bash
cd ai-metadata-enricher-infra
bash scripts/validate-environment.sh --environment <ENV> --verbose
```

Expected output: `PASS: 30  FAIL: 0  SKIP: 0`

---

## Step 11: Run E2E Tests

### Assign RBAC for your user (if running tests locally):

Your user needs:
- Cosmos DB Data Contributor (data-plane)
- Cognitive Services OpenAI Contributor
- Service Bus Data Sender + Receiver
- Search Index Data Reader

(Same pattern as Step 7, but with `principalType: User`)

### Run tests:

```bash
cd ai-metadata-enricher

# Unit tests
python -m pytest tests/ -v --tb=short

# E2E against target environment
ENVIRONMENT=<ENV> \
PYTHONPATH="$(pwd)" \
PYTHONIOENCODING=utf-8 \
python scripts/e2e_prod_validation.py
```

Expected output: `RESULT: ALL CHECKS PASSED`

---

## Summary of Resources Created

| Resource | Name Pattern | Example (prod) |
|----------|-------------|----------------|
| Resource Group | `rg-ai-metadata-<ENV>` | `rg-ai-metadata-prod` |
| Cosmos DB | `cosmos-ai-metadata-<ENV>` | `cosmos-ai-metadata-prod` |
| Service Bus | `ai-metadata-<ENV>-sbus` | `ai-metadata-prod-sbus` |
| Event Hub NS | `ai-metadata-<ENV>-eh` | `ai-metadata-prod-eh` |
| AI Search | `ai-metadata-<ENV>-search` | `ai-metadata-prod-search` |
| OpenAI | `oai-ai-metadata-<ENV>` | `oai-ai-metadata-prod` |
| ACR | `craimetadata<env>` | `craimetadataprod` |
| Container App | `ca-orchestrator-ai-metadata-<ENV>` | `ca-orchestrator-ai-metadata-prod` |
| CAE | `cae-ai-metadata-<ENV>` | `cae-ai-metadata-prod` |
| Function App | `func-bridge-ai-metadata-<ENV>` | `func-bridge-ai-metadata-prod` |
| Log Analytics | `log-ai-metadata-<ENV>` | `log-ai-metadata-prod` |
| App Insights | `appi-ai-metadata-<ENV>` | `appi-ai-metadata-prod` |
| Purview | `purview-ai-metadata-<ENV>` | `purview-ai-metadata-prod` |
| Storage | `aimetadata<env>st<unique>` | `aimetadataprodstg23wpbcj` |

---

## Automated Deployment (Single Command)

For environments with an existing parameter file, use the master deployment script:

```bash
cd ai-metadata-enricher-infra

bash scripts/deploy-environment.sh \
  --environment <ENV> \
  --subscription-id <SUB_ID> \
  --app-repo-path ../ai-metadata-enricher \
  --verbose
```

This script orchestrates all 9 phases automatically:
1. Pre-flight checks (az, docker, params)
2. Bicep Pass 1 (core resources)
3. Purview account creation (with wait loop)
4. Docker image build + push to ACR
5. Bicep Pass 2 (compute + functions + purview)
6. Bridge Function deploy (zip deployment)
7. Purview bootstrap (AI_Enrichment type + Data Curator RBAC)
8. Purview source registration + scan trigger
9. Environment validation (30 checks)

**Guardrails:** Prompts for confirmation on `prod`/`production`. Never deletes. Idempotent (safe to re-run). Auto-retries Container App AcrPull failure.

**Tested:** Successfully deployed prod from zero in ~13 minutes, achieving 30/30 validation checks.

---

## What IaC Creates vs What It Cannot

### Fully Automated via Bicep (ARM)

All 22 Azure resources, 8 RBAC role assignments, diagnostic settings, container configuration, and function app settings.

### Automated via Scripts (NOT possible via Bicep/ARM)

These items use Azure data-plane APIs that ARM/Bicep cannot access:

| Item | Script | API Used | Why Not Bicep |
|------|--------|----------|---------------|
| Purview account creation | `deploy-environment.sh` Phase 3 | `az purview account create` | Could be Bicep, but kept separate for governance control |
| AI_Enrichment Business Metadata type | `bootstrap-purview.sh` | Atlas v2 REST API (POST) | Purview data-plane only |
| Data Curator collection RBAC | `bootstrap-purview.sh` | Metadata Policy REST API | Purview collection RBAC, not ARM RBAC |
| Purview source registration | `setup-purview-sources.sh` | Scan Management REST API | Purview data-plane only |
| Purview scan configuration | `setup-purview-sources.sh` | Scan Management REST API | Purview data-plane only |
| Container image build + push | `deploy-environment.sh` Phase 4 | Docker CLI + `az acr` | Requires local Docker daemon |
| Bridge Function code deploy | `deploy-environment.sh` Phase 6 | `az functionapp deployment` | Code packaging is not ARM |

### Truly Manual (cannot be automated)

| Item | Why | When Needed |
|------|-----|-------------|
| Purge soft-deleted OpenAI account | Required when re-creating in same subscription after deletion | Only on re-deploy after destroy |
| SQL Server `db_datareader` for Purview MI | Requires SQL admin access to target database | Only when adding SQL scan source |
| Purview scan schedule | Not yet implemented in scripts | Configure via portal or extend `setup-purview-sources.sh` |
| Search index context documents | Application-specific data, not infrastructure | Upload via admin key or indexer |

---

## Known Issues and Lessons Learned

### 1. Cosmos Free Tier (one per subscription)
**Problem:** `enableFreeTier: true` fails if another account already uses free tier.
**Fix:** Set `enableFreeTier = false` in parameters.

### 2. Container App AcrPull Chicken-and-Egg
**Problem:** Container App needs AcrPull RBAC to pull image, but RBAC is assigned after CA creation.
**Fix:** `deploy-environment.sh` automatically assigns AcrPull via REST API and retries the Bicep deploy. Expect 2 Bicep passes on first deploy.

### 3. Azure CLI `az role assignment create` MissingSubscription
**Problem:** In some environments, `az role assignment create` fails with `MissingSubscription`.
**Fix:** All scripts use `az rest --method put` with full ARM URL instead.

### 4. Purview Type Creation (POST vs PUT)
**Problem:** PUT fails with 404 on new Purview accounts.
**Fix:** `bootstrap-purview.sh` now tries POST first, falls back to PUT for updates.

### 5. OpenAI Soft-Delete on Re-deploy
**Problem:** After deleting and re-creating an environment in the same subscription, Azure OpenAI account creation fails because the old account is soft-deleted.
**Fix:** Purge before re-deploy: `az cognitiveservices account purge --name oai-ai-metadata-<ENV> --resource-group rg-ai-metadata-<ENV> --location eastus`

### 6. Search Indexers (0 items)
**Problem:** Indexers run before blobs are uploaded, resulting in 0 items indexed.
**Fix:** Upload data first, then trigger indexer, or push documents directly via Search REST API.

### 7. Function App State (Flex Consumption)
**Problem:** `az functionapp show --query state` returns `None` for FC1 plans.
**Fix:** Validation script checks existence via `--query name` instead.

### 8. Search provisioningState Case
**Problem:** `az search service show` returns `succeeded` (lowercase).
**Fix:** Case-insensitive comparison in validation scripts.

### 9. RBAC Scope Case Sensitivity
**Problem:** Azure returns `resourcegroups` (lowercase) in role assignments but `resourceGroups` (mixed) in resource IDs.
**Fix:** Validation script uses `contains()` with resource name instead of exact scope match.

### 10. Bridge Function Zip Format (Flex Consumption)
**Problem:** Flex Consumption requires `.azurefunctions/` directory at zip root level.
**Fix:** `deploy-environment.sh` builds the zip from `publish_v3/` which includes this directory.

---

## Estimated Costs (per month)

| Resource | Dev (free tier) | Prod |
|----------|----------------|------|
| Cosmos DB | Free (400 RU/s) | ~$24 (400 RU/s) |
| Service Bus Standard | ~$10 | ~$10 |
| Event Hub Standard | ~$11 | ~$11 |
| AI Search Basic | ~$75 | ~$75 |
| OpenAI (10K TPM) | Pay per token | Pay per token |
| Container Apps | ~$0 (idle) | ~$5 (low usage) |
| Functions FC1 | ~$0 (idle) | ~$0 (low usage) |
| Log Analytics | ~$2 (30 days) | ~$5 (30 days) |
| Purview | ~$0.25/hour | ~$0.25/hour (~$180/mo) |
| ACR Basic | ~$5 | ~$5 |
| Storage GRS | ~$2 | ~$4 |
| **Total** | **~$100** | **~$325** |

---

## Clean Up (Delete Environment)

```bash
# Delete resource group (deletes all resources)
az group delete --name rg-ai-metadata-<ENV> --yes --no-wait

# Purview soft-delete cleanup (if needed)
az purview account delete --name purview-ai-metadata-<ENV> -g rg-ai-metadata-<ENV> --yes
```

**Warning:** This permanently deletes all resources and data in the environment.
