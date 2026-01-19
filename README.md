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

## Baseline: Naming, Tagging, and Environment Isolation

**This section formalizes the naming conventions, mandatory tags, and environment isolation strategy implemented in the Bicep code. This baseline is now frozen for the MVP.**

### Naming Conventions

All resource names follow a standardized pattern to ensure consistency, environment isolation, and global uniqueness where required.

#### General Naming Pattern

**Resource Group**:
```
rg-${projectName}-${environment}
```
- Example (Dev): `rg-aime-dev`
- Pattern defined in: [infra/main.bicep](infra/main.bicep#L63)

**Resource Prefix** (used by all other resources):
```
${projectName}-${environment}
```
- Example (Dev): `aime-dev`
- Pattern defined in: [infra/core/main.bicep](infra/core/main.bicep#L31)

#### Resource-Specific Naming

| Resource Type | Naming Pattern | Example (Dev) | Bicep Location |
|---------------|----------------|---------------|----------------|
| **Storage Account** | `${prefix}st${uniqueString}` (alphanumeric, max 24 chars) | `aimedevstxyz123` | [infra/storage/main.bicep](infra/storage/main.bicep#L40) |
| **Cosmos DB Account** | `${prefix}-cosmos-${uniqueString}` (max 44 chars) | `aime-dev-cosmos-xyz123` | [infra/cosmos/main.bicep](infra/cosmos/main.bicep#L48) |
| **Azure AI Search** | `${prefix}-search` | `aime-dev-search` | [infra/search/main.bicep](infra/search/main.bicep#L34) |
| **Service Bus Namespace** | `${prefix}-sb` | `aime-dev-sb` | [infra/messaging/main.bicep](infra/messaging/main.bicep#L43) |

#### Global Uniqueness Strategy

For resources requiring globally unique names (Storage, Cosmos DB):
- **Auto-generated suffix**: `uniqueString(resourcePrefix)` generates a deterministic hash
- **Manual suffix**: Optional `uniqueSuffix` parameter for explicit control
- Defined in: [infra/storage/main.bicep](infra/storage/main.bicep#L40), [infra/cosmos/main.bicep](infra/cosmos/main.bicep#L48)

#### Naming Rules (Frozen for MVP)

✅ **MANDATORY**:
- All resource names MUST include the environment (`dev`, `test`, `prod`)
- Naming patterns MUST be consistent across all environments
- No hardcoded environment values in resource names

❌ **PROHIBITED**:
- Manual resource naming (must use centralized patterns)
- Environment-specific naming logic (use parameterization)

---

### Mandatory Tags

All resources inherit a standardized set of tags defined centrally in the `core` module.

#### Tag Definition

```bicep
{
  environment: string   // 'dev', 'test', or 'prod'
  project: string       // 'aime' (AI Metadata Enricher)
  managedBy: string     // 'bicep' (governance marker)
}
```

**Defined in**: [infra/core/main.bicep](infra/core/main.bicep#L19-L22)

#### Tag Purpose

| Tag | Purpose | Example Value |
|-----|---------|---------------|
| `environment` | Identify deployment environment; enable cost tracking and RBAC policies | `dev` |
| `project` | Group resources by project; enable cross-resource queries | `aime` |
| `managedBy` | Indicate infrastructure is managed as code (not manually created) | `bicep` |

#### Tag Propagation

- Tags are defined **once** in the `core` module
- Propagated to all downstream modules via `core.outputs.resourceTags`
- Applied to: Resource Group, Storage Account, Cosmos DB, Azure AI Search, Service Bus
- **No tag duplication** across modules (single source of truth)

#### Tag Inheritance (Frozen for MVP)

✅ **MANDATORY**:
- All resources MUST inherit tags from `core` module
- No module-specific tag overrides

❌ **PROHIBITED**:
- Hardcoding tags in individual modules
- Adding new tags without updating `core` module

---

### Dev Environment Isolation

The Dev environment is isolated from Test and Prod through dedicated resources and environment-scoped naming.

#### Isolation Mechanisms

1. **Dedicated Resource Group**: `rg-aime-dev`
   - No resources shared with Test or Prod
   - Complete isolation of Dev environment

2. **Environment-Scoped Naming**: All resources include `-dev` in their names
   - Prevents naming collisions
   - Clear visual separation in Azure Portal

3. **Parameterization**: Environment is a parameter, not hardcoded
   - Defined in: [infra/parameters.dev.bicepparam](infra/parameters.dev.bicepparam#L18)
   - Same Bicep code deploys all environments with different parameter files

#### Test and Prod Deployment Strategy

Test and Prod environments will:
- ✅ **Reuse** the same Bicep modules (no code changes)
- ✅ **Use** different parameter files (`parameters.test.bicepparam`, `parameters.prod.bicepparam`)
- ✅ **Deploy** to separate resource groups (`rg-aime-test`, `rg-aime-prod`)

**No structural changes required** — only parameter values differ.

---

### What Changes vs. What Stays Constant Across Environments

#### MAY Change Between Environments

The following **MAY** be adjusted via parameter files for Test/Prod:

- **SKUs**: Storage redundancy (LRS → ZRS/GRS), Search tier (Basic → Standard), Service Bus tier
- **Scaling**: Cosmos DB throughput, Search replicas/partitions
- **Security**: Private Endpoints, VNet integration, firewall rules
- **Quotas**: TTL values, retention policies, message limits
- **Location**: Azure region (currently `eastus` for Dev)

**Configured in**: Environment-specific `.bicepparam` files

#### MUST NOT Change Between Environments

The following **MUST remain constant** across all environments:

- **Naming patterns**: Resource naming conventions (frozen above)
- **Tag structure**: Tag keys and propagation logic
- **Resource boundaries**: Same resource types in all environments
- **Data contracts**: Cosmos DB partition key (`/entityType`), TTL structure
- **Index schemas**: Azure AI Search index schema (frozen contract)
- **Queue contracts**: Service Bus queue names and configuration

**Enforced by**: Shared Bicep modules with parameterized values only

---

### Baseline Validation Procedure

Before deploying to any environment, perform the following validation steps:

#### 1. Template Validation

```powershell
az deployment sub validate \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/parameters.dev.bicepparam
```

**Expected Result**: `"provisioningState": "Succeeded"`

**What to verify**:
- No syntax errors
- All parameters resolved correctly
- Resource dependencies valid

---

#### 2. What-If Preview

```powershell
az deployment sub what-if \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/parameters.dev.bicepparam
```

**What to verify**:

✅ **Naming Compliance**:
- Resource Group: `rg-aime-dev`
- Storage Account: `aimedevst*` (alphanumeric only)
- Cosmos DB: `aime-dev-cosmos-*`
- Azure AI Search: `aime-dev-search`
- Service Bus: `aime-dev-sb`

✅ **Tag Compliance**:
- All resources have `environment: dev`
- All resources have `project: aime`
- All resources have `managedBy: bicep`

✅ **Environment Isolation**:
- All resource names include environment (`dev`)
- No shared resources with other environments

✅ **Resource Count**:
- 1 Resource Group
- 1 Storage Account + 4 Blob Containers
- 1 Cosmos DB Account + 1 Database + 2 Containers
- 1 Azure AI Search Service
- 1 Service Bus Namespace + 1 Queue

---

#### 3. Post-Deployment Verification

```powershell
# List all resources
az resource list --resource-group rg-aime-dev --output table

# Verify tags
az resource list --resource-group rg-aime-dev \
  --query "[].{Name:name, Environment:tags.environment, Project:tags.project}" \
  --output table
```

**What to verify**:
- All resources deployed successfully
- Naming matches expected patterns
- Tags applied consistently

---

### Baseline Freeze Statement

**This naming, tagging, and environment isolation baseline is now frozen for the MVP.**

- **Freeze Date**: January 19, 2026
- **Execution Plan Reference**: Phase 1 — Infrastructure Foundation (Passive Resources)
- **Scope**: All naming conventions, mandatory tags, and environment isolation rules defined above

**Changes to this baseline require**:
- Architectural review
- Impact analysis on existing Test/Prod environments (future)
- Explicit approval from platform governance

**Rationale**: Freezing the baseline ensures deterministic, reproducible deployments and prevents drift between environments.

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
