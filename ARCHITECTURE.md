# Architecture Overview

## AI Metadata Enricher Platform - Infrastructure Foundation

This document provides a high-level architectural overview of the infrastructure created by this repository.

---

## Architecture Diagram (Conceptual)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure Subscription                            │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  Resource Group: rg-aime-dev                                │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │  Azure Storage Account                               │  │    │
│  │  │  - Container: synergy                                │  │    │
│  │  │  - Container: zipline                                │  │    │
│  │  │  - Container: documentation                          │  │    │
│  │  │  - Container: schemas                                │  │    │
│  │  │  - Managed Identity (System-Assigned)                │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │  Azure Cosmos DB (NoSQL API)                         │  │    │
│  │  │  - Database: enricher-db                             │  │    │
│  │  │    - Container: state (TTL: 7 days)                  │  │    │
│  │  │    - Container: audit (TTL: 180 days)                │  │    │
│  │  │  - Partition Key: /entityType                        │  │    │
│  │  │  - Managed Identity (System-Assigned)                │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │  Azure AI Search                                     │  │    │
│  │  │  - Service: Basic tier                               │  │    │
│  │  │  - Index: metadata-index (manual creation required)  │  │    │
│  │  │  - Managed Identity (System-Assigned)                │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │  Azure Service Bus                                   │  │    │
│  │  │  - Namespace: Standard tier                          │  │    │
│  │  │  - Queue: enrichment-requests                        │  │    │
│  │  │  - DLQ: enrichment-requests/$DeadLetterQueue         │  │    │
│  │  │  - Managed Identity (System-Assigned)                │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  │                                                              │    │
│  │  [FUTURE: Azure Container Apps]                             │    │
│  │  [FUTURE: Azure Key Vault]                                  │    │
│  │  [FUTURE: Azure Monitor / Application Insights]             │    │
│  │                                                              │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  [EXTERNAL: Microsoft Purview - Manual Configuration]               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

### Azure Storage Account
**Purpose**: Persistent storage for enrichment artifacts and schemas

**Containers**:
- `synergy`: Primary storage for enrichment artifacts and processed metadata
- `zipline`: Transient/pipeline storage for in-flight processing
- `documentation`: Documentation and reference materials
- `schemas`: JSON schemas and contracts

**Security**: System-assigned Managed Identity, RBAC-based access, TLS 1.2+

---

### Azure Cosmos DB (NoSQL API)
**Purpose**: State management and audit logging

**Containers**:
- `state`: Transient operational state (auto-expires after 7 days)
  - Use case: Track enrichment job status, progress, and temporary metadata
- `audit`: Compliance and audit trail (auto-expires after 180 days)
  - Use case: Log all enrichment operations, AI decisions, and governance actions

**Partition Key**: `/entityType` (consistent across containers)

**Security**: System-assigned Managed Identity, RBAC-based access, Serverless billing model

---

### Azure AI Search
**Purpose**: Searchable metadata index for enrichment discovery

**Index Schema** (frozen for MVP contract):
- `id`: Unique identifier (key)
- `entityType`: Type of metadata entity (filterable)
- `title`: Entity title (searchable)
- `description`: Original description (searchable)
- `suggestedDescription`: AI-generated description candidate (searchable, filterable)
- `tags`: Metadata tags (searchable, filterable, facetable)
- `createdAt`: Creation timestamp (filterable, sortable)
- `updatedAt`: Last update timestamp (filterable, sortable)

**Note**: Index must be created manually post-deployment (Bicep limitation)

**Security**: System-assigned Managed Identity, RBAC-based access

---

### Azure Service Bus
**Purpose**: Event-driven messaging for enrichment requests

**Queues**:
- `enrichment-requests`: Main queue for enrichment job requests
- `enrichment-requests/$DeadLetterQueue`: Automatic DLQ for failed messages

**Configuration**:
- Max delivery count: 10 attempts before moving to DLQ
- Message TTL: 7 days
- Lock duration: 5 minutes

**Security**: System-assigned Managed Identity, RBAC-based access

---

### Microsoft Purview (External)
**Purpose**: Governed metadata catalog integration

**Configuration** (Manual):
- Custom attribute: `suggestedDescription` (AI-writable)
- Official `description` field: **NEVER written by AI** (human governance)

**Integration Points**:
- **Read**: AI reads existing metadata from Purview
- **Write**: AI writes suggestions to `suggestedDescription` only
- **Audit**: All Purview write operations logged to Cosmos DB `audit` container

**Note**: Purview resources NOT created by this repository. See [infra/purview/README.md](infra/purview/README.md)

---

## Data Flow (Future State with Compute)

```
1. Event Trigger → Service Bus Queue
   ↓
2. Orchestrator (Container App) → Reads from Queue
   ↓
3. Orchestrator → Queries Purview for metadata
   ↓
4. Orchestrator → Stores job state in Cosmos DB (state container)
   ↓
5. Enrichment Worker (Container App) → Processes enrichment
   ↓
6. Worker → Generates AI suggestion (LLM call)
   ↓
7. Worker → Writes suggestion to Purview (suggestedDescription attribute)
   ↓
8. Worker → Logs operation to Cosmos DB (audit container)
   ↓
9. Worker → Updates AI Search index with enriched metadata
   ↓
10. Worker → Completes queue message or moves to DLQ on failure
```

---

## Security Architecture

### Authentication
- **Managed Identity**: System-assigned identities for all resources
- **RBAC**: Role-based access control (no connection strings in production)
- **TLS**: Enforced TLS 1.2+ for all connections

### Network Security (Dev Environment)
- **Public Endpoints**: All resources use public endpoints for simplicity
- **No VNet**: No VNet integration or Private Endpoints in Dev
- **Firewall**: Allow all traffic (Dev only)

### Network Security (Future: Test/Prod)
- **Private Endpoints**: Secure all resources via Private Endpoints
- **VNet Integration**: Container Apps and resources in VNets
- **Firewall Rules**: IP whitelisting and network isolation
- **Key Vault**: Store secrets and connection strings

---

## Governance and Compliance

### Data Retention
- **State Data**: 7-day TTL (auto-delete)
- **Audit Logs**: 180-day TTL (auto-delete)
- **Blob Storage**: 7-day soft delete retention (Dev)

### Audit Trail
All enrichment operations logged to Cosmos DB `audit` container:
- Timestamp
- Entity ID
- Suggested description
- AI confidence score
- User/system context

### Purview Integration
- AI **NEVER** writes to official `description` field
- AI writes only to custom `suggestedDescription` attribute
- Human data stewards review and approve suggestions

---

## Scalability Considerations

### Current (Dev)
- Cosmos DB: Serverless (auto-scales)
- Storage: Standard LRS (locally redundant)
- Service Bus: Standard tier (up to 1000 messages/sec)
- AI Search: Basic tier (3 replicas, 1 partition)

### Future (Test/Prod)
- Cosmos DB: Provisioned throughput or autoscale
- Storage: Zone-redundant or geo-redundant
- Service Bus: Premium tier (higher throughput, VNet support)
- AI Search: Standard tier (more replicas, partitions, semantic search)
- Container Apps: Multi-replica, autoscaling based on queue depth

---

## Cost Optimization

### Dev Environment
- Cosmos DB: Serverless (pay-per-operation)
- Storage: Locally redundant, Hot tier
- Service Bus: Standard tier (cost-effective for Dev)
- AI Search: Basic tier (low-cost for Dev)

### Future Optimization
- Use Azure Cost Management for monitoring
- Right-size resources based on usage patterns
- Consider Reserved Instances for predictable workloads

---

## Monitoring and Observability (Future)

Planned integrations:
- **Azure Monitor**: Resource metrics and logs
- **Application Insights**: Distributed tracing, performance monitoring
- **Log Analytics**: Centralized logging and querying
- **Alerts**: Automated alerts for failures, high latency, cost anomalies

---

## Disaster Recovery (Future)

Planned capabilities:
- **Backup**: Cosmos DB continuous backup (point-in-time restore)
- **Geo-Replication**: Storage geo-redundancy for critical data
- **Multi-Region**: Cosmos DB multi-region writes (Test/Prod)

---

## References

- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/architecture/framework/)
- [Azure Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Container Apps Documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Microsoft Purview Documentation](https://learn.microsoft.com/en-us/purview/)

---

**Document Version**: 1.0  
**Last Updated**: January 2026
