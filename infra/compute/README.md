# Compute Resources (Future Implementation)

## Overview

**NO COMPUTE RESOURCES ARE CREATED AT THIS STAGE.**

This is an intentional architectural and execution-plan decision. The infrastructure created by this repository provides the **passive foundation** (storage, databases, messaging, search) for the AI Metadata Enricher platform.

Compute resources—specifically **Azure Container Apps**—will be created in a **future phase** after the foundational infrastructure is validated and operational.

---

## Planned Compute Architecture

### Azure Container Apps

The platform will use **Azure Container Apps** as the primary compute runtime for:

1. **Orchestrator Service**  
   - Listens to Service Bus queue (`enrichment-requests`)
   - Coordinates enrichment workflows
   - Manages state in Cosmos DB

2. **Enrichment Worker Services**  
   - Process enrichment requests from the queue
   - Generate AI-powered metadata suggestions
   - Write suggestions to Purview custom attribute (`suggestedDescription`)
   - Store audit logs in Cosmos DB

3. **Background Jobs (Optional)**  
   - Scheduled jobs for batch enrichment
   - Monitoring and health checks

### Key Features (Future)

- **Managed Identity**: All services will authenticate to Azure resources using system-assigned Managed Identities
- **RBAC**: Fine-grained role assignments for Storage, Cosmos DB, Service Bus, AI Search, and Purview
- **Scaling**: Container Apps will scale based on queue depth and resource utilization
- **Environment Variables**: Configuration (endpoints, connection strings) will be injected via Container Apps environment variables
- **Private Networking (Test/Prod)**: Container Apps will connect to resources via VNet integration and Private Endpoints in higher environments

---

## Why Not Create Compute Now?

### Separation of Concerns

- **Infrastructure Layer** (this repository): Establishes the governed, event-driven foundation
- **Application Layer** (future): Implements business logic, orchestration, and LLM integration

### Execution Plan Phasing

1. **Phase 1 (Current)**: Deploy passive infrastructure (storage, databases, messaging, search)
2. **Phase 2 (Future)**: Develop and containerize the orchestrator and worker services
3. **Phase 3 (Future)**: Deploy Container Apps and connect to the infrastructure
4. **Phase 4 (Future)**: Test, iterate, and promote to Test/Prod environments

### Risk Mitigation

- Validate infrastructure independently before adding compute complexity
- Ensure all passive resources are correctly configured and accessible
- Avoid coupling infrastructure changes with application logic changes

---

## What to Do Next

When you are ready to implement compute resources:

1. **Create a Container Apps Environment**  
   - Use Bicep to define the Container Apps Environment
   - Configure VNet integration if using Private Endpoints (Test/Prod)

2. **Define Container Apps**  
   - Create Bicep modules for each container app (orchestrator, workers)
   - Configure environment variables (Storage endpoint, Cosmos endpoint, Service Bus endpoint, etc.)
   - Assign Managed Identities and RBAC roles

3. **Implement Application Logic**  
   - Develop the orchestrator and worker services (separate repository or folder)
   - Containerize using Docker
   - Push container images to Azure Container Registry (ACR)

4. **Deploy and Test**  
   - Deploy Container Apps via Bicep
   - Test end-to-end workflows (queue → enrichment → Purview)
   - Monitor logs, metrics, and audit trails

---

## Placeholder Bicep Module (Example)

When you are ready, you can create a Bicep module like this:

```bicep
// infra/compute/main.bicep (Future Implementation)

@description('The resource name prefix')
param resourcePrefix string

@description('The Azure region for resources')
param location string

@description('Tags to apply to resources')
param tags object

// Container Apps Environment
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${resourcePrefix}-cae'
  location: location
  tags: tags
  properties: {
    // Configuration here
  }
}

// Orchestrator Container App (Example)
resource orchestratorApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${resourcePrefix}-orchestrator'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    // Configuration here
  }
}

// Outputs
output containerAppsEnvironmentId string = containerAppsEnvironment.id
```

---

## References

- [Azure Container Apps Documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Container Apps with Managed Identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity)
- [Azure Container Apps Scaling](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)

---

**Note**: This README serves as a contract and roadmap for future compute implementation. Do not create compute resources in this phase.
