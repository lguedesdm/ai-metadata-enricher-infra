# AI Metadata Enricher - Infrastructure as Code

**Infrastructure repository for the AI Metadata Enricher platform**  
Bicep-based, Dev-first MVP for enterprise and public-sector environments.

---

## Overview

This repository defines the **passive infrastructure foundation** for the AI Metadata Enricher platform using **Azure Bicep**. It creates the governed, event-driven Azure resources required by the enrichment system.

**This is a platform/foundation layer, not an application repository.**

---

## What This Repository Creates

This repository deploys the following resources to the **Dev environment**:

### ✅ Core Infrastructure
- **Resource Group**: `rg-aime-dev` (AIME = AI Metadata Enricher)
- **Naming conventions and tagging standards**

### ✅ Storage
- **Azure Storage Account** with blob containers:
  - `synergy`: Primary storage for enrichment artifacts
  - `zipline`: Transient/pipeline storage
  - `documentation`: Documentation and reference materials
  - `schemas`: JSON schemas and contracts

### ✅ Cosmos DB
- **Azure Cosmos DB** (NoSQL API) with:
  - Shared database: `enricher-db`
  - Containers:
    - `state`: Transient operational state (TTL = 7 days)
    - `audit`: Audit trail and compliance logging (TTL = 180 days)
  - Partition key: `/entityType`

### ✅ Azure AI Search
- **Search service** (Basic tier for Dev)
- **Search index schema** (frozen contract for MVP)
  - Fields: `id`, `entityType`, `title`, `description`, `suggestedDescription`, `tags`, `createdAt`, `updatedAt`
  - Note: Index must be created manually or via post-deployment script (Bicep limitation)

### ✅ Service Bus
- **Service Bus Namespace** with:
  - Main queue: `enrichment-requests`
  - Dead-letter queue: Auto-configured by Azure

### ✅ Managed Identities
- System-assigned Managed Identities for all applicable resources
- RBAC-based authentication (no connection strings in production)

### ✅ Microsoft Purview (Documentation Only)
- Custom attribute specification: `suggestedDescription`
- **Important**: Purview resources are NOT created by Bicep. See [infra/purview/README.md](infra/purview/README.md) for configuration instructions.

---

## What This Repository Does NOT Create

By architectural and execution-plan decision, the following are **intentionally excluded**:

### ❌ Compute Resources
- No Azure Functions
- No Azure Container Apps
- No Azure Container Instances
- No Jobs or batch processing

**Rationale**: Compute resources (Azure Container Apps) will be created in a **future phase** after the foundational infrastructure is validated. See [infra/compute/README.md](infra/compute/README.md) for details.

### ❌ CI/CD Pipelines
- No GitHub Actions workflows
- No Azure DevOps pipelines

### ❌ Application Logic
- No orchestrator or worker code
- No queue consumers
- No LLM integrations

### ❌ Advanced Networking (Dev Only)
- No VNets or Private Endpoints (Dev uses public endpoints)
- No advanced firewall rules
- Networking will be added for Test/Prod environments

---

## Repository Structure

```
ai-metadata-enricher-infra/
├── infra/
│   ├── core/                  # Resource group, naming, tags
│   │   └── main.bicep
│   ├── storage/               # Storage account and blob containers
│   │   └── main.bicep
│   ├── cosmos/                # Cosmos DB account, database, containers, TTL
│   │   └── main.bicep
│   ├── search/                # Azure AI Search service and index
│   │   └── main.bicep
│   ├── messaging/             # Service Bus namespace and queues
│   │   └── main.bicep
│   ├── purview/               # Purview documentation (no resources created)
│   │   └── README.md
│   ├── compute/               # Compute placeholder (no resources created)
│   │   └── README.md
│   ├── main.bicep             # Main orchestration file
│   └── parameters.dev.bicep   # Dev environment parameters
├── README.md                  # This file
└── .gitignore
```

---

## Prerequisites

- **Azure CLI** (version 2.50.0 or later)
- **Azure subscription** with sufficient permissions to create resources
- **Bicep CLI** (installed with Azure CLI)
- **Owner or Contributor** role on the subscription

---

## Deployment Instructions

### 1. Authenticate to Azure

```powershell
az login
az account set --subscription <subscription-id>
```

### 2. Validate the Deployment (What-If)

Run a what-if analysis to preview changes without deploying:

```powershell
az deployment sub what-if `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicep
```

### 3. Validate the Bicep Template

Validate the Bicep syntax and structure:

```powershell
az deployment sub validate `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicep
```

### 4. Deploy the Infrastructure

Deploy the Dev environment:

```powershell
az deployment sub create `
  --name ai-enricher-dev-deployment `
  --location eastus `
  --template-file infra/main.bicep `
  --parameters infra/parameters.dev.bicep
```

### 5. Verify the Deployment

After deployment completes, verify the resources in the Azure Portal or via Azure CLI:

```powershell
az resource list --resource-group rg-aime-dev --output table
```

### 6. Post-Deployment Steps

#### Create Azure AI Search Index

Bicep does not natively support creating search indexes. Create the index manually:

1. Navigate to the Azure Portal
2. Open the Azure AI Search service (`aime-dev-search`)
3. Go to **Indexes** → **Add Index**
4. Use the schema defined in [infra/search/main.bicep](infra/search/main.bicep) (see `indexSchema` variable)

Alternatively, use the Azure CLI or REST API to create the index programmatically.

#### Configure Microsoft Purview (Optional)

Follow the instructions in [infra/purview/README.md](infra/purview/README.md) to configure the custom attribute `suggestedDescription` in Purview.

---

## Configuration

### Environment-Specific Parameters

- **Dev**: [infra/parameters.dev.bicepparam](infra/parameters.dev.bicepparam)
- **Test**: Create `infra/parameters.test.bicepparam` (not yet implemented)
- **Prod**: Create `infra/parameters.prod.bicepparam` (not yet implemented)

### Customization

To customize the deployment, edit the parameters in [infra/parameters.dev.bicepparam](infra/parameters.dev.bicepparam):

- `location`: Azure region (e.g., `eastus`, `westeurope`)
- `storageSku`: Storage redundancy (`Standard_LRS`, `Standard_GRS`, `Standard_ZRS`)
- `searchSku`: Search service tier (`free`, `basic`, `standard`)
- `serviceBusSku`: Service Bus tier (`Basic`, `Standard`, `Premium`)

---

## Security Considerations

### Dev Environment (MVP)
- **Public endpoints**: All resources use public endpoints for simplicity
- **Managed Identity**: System-assigned identities for authentication
- **RBAC**: Role-based access control (no connection strings)
- **TLS**: Enforced TLS 1.2+ for all connections

### Test/Prod Environments (Future)
- **Private Endpoints**: Secure resources via Private Endpoints
- **VNet Integration**: Container Apps and resources in VNets
- **Key Vault**: Store secrets and connection strings in Azure Key Vault
- **Advanced Firewall Rules**: IP whitelisting and network isolation

---

## Architecture Principles

### MVP-First Simplicity
- Solve only what is urgently complex
- Defer non-critical features to future iterations
- Clear comments for future evolution

### Dev-Only Deployment
- Create only the Dev environment
- Structure parameterized and ready for Test/Prod
- Test/Prod environments NOT created at this stage

### Deterministic and Governed
- Infrastructure as Code (Bicep only)
- No manual resource creation (except Purview and Search index)
- Reproducible deployments

---

## Future Enhancements

The following features are deferred to future iterations:

1. **Compute Resources** (Azure Container Apps)
   - Orchestrator service
   - Enrichment worker services
   - Background jobs

2. **Advanced Networking**
   - VNet integration
   - Private Endpoints
   - Firewall rules

3. **CI/CD Pipelines**
   - GitHub Actions or Azure DevOps
   - Automated deployments
   - Environment promotion (Dev → Test → Prod)

4. **Monitoring and Observability**
   - Azure Monitor
   - Application Insights
   - Log Analytics

5. **Advanced Security**
   - Azure Key Vault for secrets
   - Customer-managed encryption keys
   - Advanced RBAC policies

---

## Troubleshooting

### Deployment Fails with "Resource already exists"

If resources already exist, delete the resource group and redeploy:

```powershell
az group delete --name rg-aime-dev --yes
```

### Cosmos DB Serverless Not Available in Region

If Cosmos DB serverless is not available in your region, modify [infra/cosmos/main.bicep](infra/cosmos/main.bicep) to use provisioned throughput instead.

### Search Index Not Created

Bicep does not natively support creating search indexes. Follow the post-deployment steps to create the index manually or via script.

---

## References

- [Azure Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Storage Documentation](https://learn.microsoft.com/en-us/azure/storage/)
- [Azure Cosmos DB Documentation](https://learn.microsoft.com/en-us/azure/cosmos-db/)
- [Azure AI Search Documentation](https://learn.microsoft.com/en-us/azure/search/)
- [Azure Service Bus Documentation](https://learn.microsoft.com/en-us/azure/service-bus-messaging/)
- [Microsoft Purview Documentation](https://learn.microsoft.com/en-us/purview/)

---

## License

[Specify your license here, e.g., MIT, Apache 2.0, or proprietary]

---

## Contact

For questions or support, contact [your-email@example.com] or open an issue in this repository.

---

**Note**: This repository is the **infrastructure foundation** for the AI Metadata Enricher platform. No compute resources are created at this stage by architectural and execution-plan decision.
