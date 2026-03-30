# AI Metadata Enricher — Infrastructure

Azure Bicep infrastructure and Bridge Functions for the AI Metadata Enricher (AIME) platform. Provisions all Azure resources, deploys the Purview Bridge Functions, and configures the event-driven pipeline that connects Purview scans to the enrichment Orchestrator.

## Architecture

```
Client's Purview Scan
  → Diagnostic Settings → Event Hub (purview-diagnostics)
  → HeuristicTriggerBridge (Azure Function) → Service Bus (purview-events)
  → UpstreamRouterFunction (Azure Function):
      Searches Purview catalog for all assets in the scanned data source
      Filters out container types (keeps tables, views)
      Sends one message per asset → Service Bus (enrichment-requests)
  → Orchestrator (Container App, separate repo) consumes and enriches
```

### Ownership Model

| Owner | Resources |
|-------|-----------|
| **AIME** | Event Hub, Bridge Functions, Service Bus, Orchestrator, AI Search, OpenAI, Cosmos DB, ACR, Storage, Observability |
| **Client** | Purview account, data sources (SQL databases), scan schedules |
| **AIME configures on client's Purview** | Diagnostic Settings, AI_Enrichment business metadata type, Data Curator + Purview Reader RBAC |

## Resources Deployed

| Resource | Naming Pattern | Purpose |
|----------|---------------|---------|
| Resource Group | `rg-ai-metadata-{env}` | Contains all resources |
| Storage Account | `aimetadata{env}st{suffix}` | Blob containers: synergy, zipline, documentation, schemas, onboarding |
| Cosmos DB | `cosmos-ai-metadata-{env}` | Database `metadata_enricher` with `state` and `audit` containers |
| Azure AI Search | `ai-metadata-{env}-search` | Index `metadata-context-index` for RAG hybrid retrieval |
| Service Bus | `ai-metadata-{env}-sbus` | Queues: `enrichment-requests`, `purview-events` |
| Event Hub | `ai-metadata-{env}-eh` | Hub: `purview-diagnostics`, consumer group: `bridge-function` |
| Azure OpenAI | `oai-ai-metadata-{env}` | GPT-4o deployment for metadata generation |
| Container Registry | `craimetadata{env}` | Orchestrator Docker images |
| Container App | `ca-orchestrator-ai-metadata-{env}` | Runs the enrichment Orchestrator |
| Function App | `func-bridge-ai-metadata-{env}` | Purview Bridge (4 functions, Flex Consumption) |
| Log Analytics | `log-ai-metadata-{env}` | Centralized logging |
| App Insights | `appi-ai-metadata-{env}` | Application telemetry |

## Bridge Functions

The Function App (`functions/purview-bridge/`) contains four functions:

| Function | Trigger | Purpose |
|----------|---------|---------|
| `HeuristicTriggerBridge` | Event Hub | Forwards Purview diagnostic events to `purview-events` Service Bus queue |
| `UpstreamRouterFunction` | Service Bus (`purview-events`) | Searches Purview for enrichable assets, sends each to `enrichment-requests` |
| `ReviewStatusPollFunction` | Timer (hourly) | Polls Cosmos for PENDING assets, syncs review status from Purview |
| `HeartbeatFunction` | Timer (hourly) | Emits liveness signal for monitoring alerts |

### Building the Bridge Function

The Function App runs on Linux (Flex Consumption Plan). When building on Windows:

```bash
cd functions/purview-bridge

# Build
dotnet publish -c Release -o publish_v3 --no-self-contained

# Remove Windows-native DLLs (cause SIGABRT on Linux)
rm publish_v3/vcruntime140*.dll publish_v3/msvcp140.dll
rm publish_v3/Microsoft.Azure.Cosmos.ServiceInterop.dll publish_v3/Cosmos.CRTCompat.dll

# Create deployment zip
# (use Python zipfile or any zip tool on publish_v3/)

# Deploy
az functionapp deployment source config-zip \
  --name func-bridge-ai-metadata-{env} \
  -g rg-ai-metadata-{env} \
  --src deploy-{env}.zip
```

### RBAC Requirements

The Bridge Function Managed Identity requires these Purview roles:

| Role | Purpose |
|------|---------|
| `data-curator` | Write enrichment results back to Purview |
| `purview-reader` | Query Purview Data Map Search API (without this, search returns 400) |

Both are configured by the `bootstrap-purview.sh` script.

## Deployment

### Prerequisites

- Azure CLI 2.50+, authenticated with Owner or Contributor role
- Docker (for building the Orchestrator image)
- .NET 8 SDK (for building the Bridge Function)
- Both repos cloned side-by-side:
  ```
  parent-dir/
  ├── ai-metadata-enricher/        # Orchestrator
  └── ai-metadata-enricher-infra/  # This repo
  ```

### Automated (Recommended)

```bash
./scripts/deploy-environment.sh \
  --environment dev \
  --subscription-id <subscription-id> \
  --app-repo-path ../ai-metadata-enricher
```

This runs 9 phases: pre-flight, Bicep Pass 1, Purview account, Docker build, Bicep Pass 2, Bridge Function deploy, Purview bootstrap, data source registration, validation.

### Manual

See [NEW-ENVIRONMENT-GUIDE.md](NEW-ENVIRONMENT-GUIDE.md) for step-by-step instructions.

### Build and Push Only (No Infra Changes)

```bash
./scripts/build-and-push.sh \
  --environment prod \
  --resource-group rg-ai-metadata-prod \
  --app-repo-path ../ai-metadata-enricher
```

## Scripts

| Script | Purpose |
|--------|---------|
| `deploy-environment.sh` | Full 9-phase automated deployment |
| `build-and-push.sh` | Build Docker image + push to ACR + deploy Bridge Function |
| `bootstrap-purview.sh` | Create AI_Enrichment type + assign Purview RBAC roles |
| `setup-purview-sources.sh` | Register SQL data source in Purview + trigger scan |
| `validate-environment.sh` | 30-point infrastructure validation |
| `infra_contract_validator.py` | Architecture drift detection |

## Repository Structure

```
ai-metadata-enricher-infra/
├── architecture/                    # Runtime architecture contract
├── infra/
│   ├── main.bicep                   # Root orchestration
│   ├── parameters.dev.bicepparam    # Dev environment config
│   ├── parameters.prod.bicepparam   # Prod environment config
│   ├── core/                        # Naming conventions, tags
│   ├── cosmos/                      # Cosmos DB + RBAC
│   ├── messaging/                   # Service Bus + RBAC
│   ├── search/                      # AI Search + RBAC
│   ├── storage/                     # Blob Storage
│   ├── compute/                     # Container App (Orchestrator)
│   ├── functions/                   # Function App (Bridge)
│   ├── registry/                    # ACR + RBAC
│   ├── eventhub/                    # Event Hub
│   ├── openai/                      # Azure OpenAI + RBAC
│   ├── observability/               # Log Analytics, App Insights, alerts
│   └── purview/                     # Diagnostic Settings
├── functions/purview-bridge/        # Bridge Function source (C#)
├── scripts/                         # Deployment and validation scripts
├── DEPLOYMENT.md                    # Quick deployment guide
└── NEW-ENVIRONMENT-GUIDE.md         # Complete step-by-step guide
```

## Security

- All resource connections use Managed Identity — no connection strings or keys in IaC
- RBAC follows least-privilege principle
- Dev uses public endpoints; prod planned with Private Endpoints

## Estimated Costs

| Environment | Monthly |
|-------------|---------|
| Dev | ~$100 |
| Prod | ~$325 |
