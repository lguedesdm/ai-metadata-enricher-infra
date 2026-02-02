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

1. Place the frozen schema at: `infra/search/schemas/metadata-context-index-v1.json`
2. Enable index deployment by setting `deploySearchIndex = true` in `infra/parameters.dev.bicepparam`
3. Deploy again using the same command in step 5

Notes:
- The script calls the Azure Search REST API (`PUT /indexes/{name}`) with the JSON body
- The index name is fixed: `metadata-context-index-v1`
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
- `serviceBusNamespaceName`: `aime-dev-sb`
- `serviceBusEndpoint`: Service Bus HTTPS endpoint
- `mainQueueName`: `enrichment-requests`
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

## Next Steps

1. **Confirm index creation** (name: `metadata-context-index-v1`)
2. **Configure Purview** (optional)
3. **Review resource configuration** in Azure Portal
4. **Plan compute layer** deployment (Azure Container Apps)
5. **Set up monitoring** (Application Insights, Log Analytics)

---

For more information, see [README.md](README.md).
