# Quick Deployment Guide

This guide provides step-by-step instructions to deploy the AI Metadata Enricher infrastructure to Azure.

## Prerequisites Checklist

- [ ] Azure CLI installed (version 2.50.0+)
- [ ] Authenticated to Azure (`az login`)
- [ ] Subscription ID known
- [ ] Owner or Contributor role on subscription

## Deployment Steps

### 1. Clone and Navigate

```powershell
cd c:\Users\leona\OneDrive\desktop\dm\ai-metadata-enricher-infra
```

### 2. Authenticate

```powershell
az login
az account set --subscription <your-subscription-id>
az account show
```

### 3. Validate Template

```powershell
az deployment sub validate `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicepparam
```

Expected: `"provisioningState": "Succeeded"`

### 4. Preview Changes (What-If)

```powershell
az deployment sub what-if `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicepparam
```

Review the output to understand what will be created.

### 5. Deploy Infrastructure

```powershell
az deployment sub create `
  --name aime-dev-deployment `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicepparam
```

**Estimated Time**: 5-10 minutes

### 6. Verify Deployment

```powershell
az resource list --resource-group rg-aime-dev --output table
```

Expected resources:
- Storage Account
- Cosmos DB Account
- Azure AI Search Service
- Service Bus Namespace

### 7. Index Deployment (Infrastructure as Code)

The unified index is created by a deploymentScript that consumes a versioned JSON schema stored in-repo. Manual portal changes are not allowed.

1. Place the frozen schema at: `infra/search/schemas/metadata-context-index.json`
2. Enable index deployment by setting `deploySearchIndex = true` in `infra/parameters.dev.bicepparam`
3. Deploy again using the same command in step 5

Notes:
- The script calls the Azure Search REST API (`PUT /indexes/{name}`) with the JSON body
- The index name is fixed: `metadata-context-index`
- The schema must include vector fields and a semantic configuration as defined in the frozen contract

### 8. Optional: Configure Purview

Follow instructions in [infra/purview/README.md](infra/purview/README.md)

## Deployment Outputs

After successful deployment, you'll receive:

- `resourceGroupName`: `rg-aime-dev`
- `storageAccountName`: `aimedevst{uniqueString}`
- `cosmosAccountName`: `aime-dev-cosmos-{uniqueString}`
- `cosmosEndpoint`: Cosmos DB HTTPS endpoint
- `searchServiceName`: `aime-dev-search`
- `searchEndpoint`: Search service HTTPS endpoint
- `serviceBusNamespaceName`: `ai-metadata-dev-sbus`
- `serviceBusEndpoint`: Service Bus HTTPS endpoint
- `purviewEventsQueueName`: `purview-events` (Bridge → here)
- `mainQueueName`: `enrichment-requests` (Orchestrator ← here)
- `deadLetterQueuePath`: `enrichment-requests/$DeadLetterQueue`

## Troubleshooting

### Issue: Storage account name already taken

**Solution**: Add a `uniqueSuffix` parameter to the deployment:

```powershell
az deployment sub create `
  --name aime-dev-deployment `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicepparam `
  --parameters uniqueSuffix=xyz123
```

### Issue: Cosmos DB serverless not available

**Solution**: Modify `infra/cosmos/main.bicep` to use provisioned throughput:

Remove the `capabilities` section and add:
```bicep
properties: {
  // ... existing properties
  // Remove capabilities section
}
```

### Issue: Permission denied

**Solution**: Ensure you have Owner or Contributor role:

```powershell
az role assignment list --assignee <your-user-id> --scope /subscriptions/<subscription-id>
```

## Clean Up

To delete all resources:

```powershell
az group delete --name rg-aime-dev --yes --no-wait
```

**Warning**: This will permanently delete all resources in the resource group.

## Recommended: Automated Deployment

For production deployments, use the automated script instead of manual steps:

```bash
cd ai-metadata-enricher-infra

bash scripts/deploy-environment.sh \
  --environment <ENV> \
  --subscription-id <SUB_ID> \
  --app-repo-path ../ai-metadata-enricher \
  --verbose
```

This orchestrates all 9 phases (Bicep, Docker, Functions, Purview bootstrap, source registration, validation). See [NEW-ENVIRONMENT-GUIDE.md](NEW-ENVIRONMENT-GUIDE.md) for full details.

## Post-Deployment: SQL Database Integration

After infrastructure is deployed, connect the client's SQL database to complete the enrichment pipeline:

1. **Client grants `db_datareader`** to the Purview MI on their SQL database
2. **Register SQL data source** via `setup-purview-sources.sh --sql-server <name> --sql-database <db>`
3. **Configure scan schedule** via Purview API (see NEW-ENVIRONMENT-GUIDE.md Step 8 Part C)
4. **Verify:** Scan discovers tables → Event Hub → Functions → Service Bus → Orchestrator enriches

Without this step, the pipeline infrastructure is deployed but has no assets to enrich.

## Next Steps

1. **Confirm index creation** (name: `metadata-context-index`)
2. **Register client SQL database** (see Post-Deployment above)
3. **Configure scan schedule** (recommended: every 3-6 hours)
4. **Upload RAG context** (Synergy/Zipline data dictionaries to blob storage)
5. **Verify end-to-end** flow with `e2e_prod_validation.py`

---

## New Environment Deployment

This section covers deploying AIME infrastructure to a new environment (test, staging, prod).

### Prerequisites

- Azure CLI 2.50.0+ installed and authenticated (`az login`)
- Owner or Contributor role on the target subscription
- Docker image built and pushed to ACR (for compute deployment)
- Purview account provisioned (if using Purview integration)

### Step 1: Create Parameter File

Copy the template and fill in environment-specific values:

```bash
cp infra/parameters.template.bicepparam infra/parameters.<env>.bicepparam
```

Edit the new file and replace all `<PLACEHOLDER>` values. Refer to `parameters.dev.bicepparam` for a working example.

Key values to configure:
- `environment` — target environment name (e.g., `test`, `staging`, `prod`)
- `location` — Azure region
- `storageSku` — use `Standard_GRS` or `Standard_RAGRS` for production
- `searchSku` — use `standard` or higher for production workloads
- `containerImage` — full ACR image URI with correct tag
- `alertEmail` — ops team email for Azure Monitor alerts

### Step 2: Validate Template

```bash
az deployment sub validate \
  --location <location> \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<env>.bicepparam
```

Expected: `"provisioningState": "Succeeded"`

### Step 3: Preview Changes (What-If)

```bash
az deployment sub what-if \
  --location <location> \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<env>.bicepparam
```

Review the output carefully. All resources should show as **Create** for a new environment.

### Step 4: Deploy Infrastructure

For a new environment, deploy incrementally in 2-3 passes to respect resource dependencies:

**Pass 1 — Core resources** (disable compute and functions):

Set `deployCompute = false`, `deployFunctions = false`, `deployRegistry = false` in your parameter file, then:

```bash
az deployment sub create \
  --name aime-<env>-pass1 \
  --location <location> \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<env>.bicepparam
```

**Pass 2 — Compute + Functions** (enable all):

Set `deployCompute = true`, `deployFunctions = true`, `deployRegistry = true`, then deploy again:

```bash
az deployment sub create \
  --name aime-<env>-pass2 \
  --location <location> \
  --template-file infra/main.bicep \
  --parameters infra/parameters.<env>.bicepparam
```

### Step 5: Bootstrap Purview

Run the Purview bootstrap script to create custom types and configure policies:

```bash
bash scripts/bootstrap-purview.sh --environment <env>
```

This creates:
- Custom type `AI_Enrichment` in Purview
- Metadata policy assignments for Orchestrator and Bridge managed identities

### Step 6: Validate Environment

Run the environment validation script to verify all 29 infrastructure checks:

```bash
bash scripts/validate-environment.sh --environment <env> --verbose
```

All checks should PASS. Address any FAILures before going live.

### Troubleshooting by Check ID

| Check | Common Cause | Fix |
|-------|-------------|-----|
| RES-001 | Resource group not created | Verify subscription and location in parameter file |
| RES-002 | Cosmos DB provisioning failed | Check region availability for serverless Cosmos |
| RES-003 | Service Bus not found | Ensure `serviceBusSku` is `Standard` or `Premium` |
| RES-004 | Event Hub NS missing | Verify `deployEventHub = true` |
| RES-005 | Search service not found | Verify `deploySearch = true` and SKU availability |
| RES-006 | OpenAI not provisioned | Check region supports Azure OpenAI; verify `deployOpenAI = true` |
| RES-007 | ACR not found | Verify `deployRegistry = true` |
| RES-008 | Container App missing | Deploy in Pass 2 with `deployCompute = true` |
| RES-009 | Function App not running | Check Function App logs; verify `deployFunctions = true` |
| RES-010 | Log Analytics missing | Verify `deployObservability = true` |
| RES-011 | Purview not found | Purview must be provisioned separately; check `purviewAccountName` |
| RBAC-001..002 | Cosmos RBAC missing | Re-run deployment — Cosmos data-plane roles are set in Bicep |
| RBAC-003..008 | ARM role missing | Re-run deployment — role assignments are set in Bicep |
| PV-001 | Custom type missing | Run `bootstrap-purview.sh` |
| PV-002..003 | MI not in policy | Run `bootstrap-purview.sh`; verify managed identity principal IDs |
| CFG-001 | Cosmos containers missing | Verify `deployCosmosContainers = true` and re-deploy |
| CFG-002 | SB queues missing | Re-run deployment — queues are created in messaging module |
| CFG-003 | Event Hub or consumer group missing | Re-run deployment — created in eventhub module |
| CFG-004 | Diagnostic settings missing | Run `bootstrap-purview.sh` or configure manually |
| CFG-005 | Search index missing | Set `deploySearchIndex = true` or create manually |
| APP-001 | Container App env vars wrong | Check Bicep compute module env var definitions |
| APP-002 | Function App settings wrong | Check Bicep functions module app settings |
| APP-003 | Placeholder container image | Push real image to ACR and update `containerImage` parameter |

---

For more information, see [README.md](README.md).
