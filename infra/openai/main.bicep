// =============================================================================
// Azure OpenAI Module
// =============================================================================
// Purpose: Provisions the Azure OpenAI account and GPT model deployment so
// the Orchestrator Container App can invoke LLM completions using
// Managed Identity.
//
// Resources created:
//   - Azure Cognitive Services account  (kind: OpenAI, SKU: S0)
//   - GPT model deployment              (configurable model and capacity)
//
// Security model:
//   The Orchestrator acquires an Entra ID token for scope
//   "https://cognitiveservices.azure.com/.default" via DefaultAzureCredential.
//   disableLocalAuth=true enforces MI-only at the platform level — no API keys
//   can be used even if someone tries to retrieve them.
//
// RBAC (Cognitive Services OpenAI User) is handled by the sibling resource in
// infra/main.bicep (openaiRbac). This decouples the RBAC assignment from the
// account provisioning and avoids a circular dependency between this module
// and the compute module (which sources openAiEndpoint from this module).
//
// Endpoint naming convention:
//   oai-{resourcePrefix}.openai.azure.com
//   e.g. oai-ai-metadata-dev.openai.azure.com
//
// Model constraints (runtime_architecture_contract.yaml):
//   defaultModel : gpt-4.x   → resolved to gpt-4o (GA, globally available)
//   temperature  : 0.1        (enforced at runtime, not configurable in IaC)
//   maxTokens    : 1024       (enforced at runtime, not configurable in IaC)
//   invocation   : RAG required before LLM call (enforced at runtime)
// =============================================================================

// =============================================================================
// PARAMETERS
// =============================================================================

@description('Resource name prefix (e.g. ai-metadata-dev)')
param resourcePrefix string

@description('Azure region for all resources')
param location string

@description('Tags to apply to all resources')
param tags object

@description('GPT model name to deploy. Must be available in the selected region.')
@allowed(['gpt-4', 'gpt-4o', 'gpt-4o-mini'])
param modelName string = 'gpt-4o'

@description('GPT model version. Must match an available version for the selected model.')
param modelVersion string = '2024-05-13'

@description('Deployment name — exposed as AZURE_OPENAI_DEPLOYMENT_NAME env var in the orchestrator.')
param deploymentName string = 'gpt-4o'

@description('Token-per-minute capacity in thousands. 10 = 10K TPM (cost-optimised for Dev).')
param capacityThousands int = 10

// =============================================================================
// LOCAL VARIABLES
// =============================================================================

// Account name follows the project naming convention documented in EnrichmentConfig:
// "https://oai-{resourcePrefix}.openai.azure.com/"
var accountName = 'oai-${resourcePrefix}'

// =============================================================================
// AZURE OPENAI ACCOUNT
// =============================================================================

resource openAiAccount 'Microsoft.CognitiveServices/accounts@2023-10-01-preview' = {
  name: accountName
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'    // Only SKU available for Azure OpenAI
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName    // Required for Entra ID token auth (FQDN)
    publicNetworkAccess: 'Enabled'      // MVP: Public endpoints for Dev
    disableLocalAuth: true              // Enforce MI-only — API keys disabled at platform level
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// =============================================================================
// GPT MODEL DEPLOYMENT
// =============================================================================
// Provisions the named deployment that the runtime addresses via
// AZURE_OPENAI_DEPLOYMENT_NAME. The deployment name is independent of the
// model name, allowing future model upgrades without env var changes.
//
// Capacity unit: 1 = 1K tokens per minute (TPM).
// Dev default: 10 = 10K TPM — sufficient for single-asset enrichment workloads.

resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = {
  parent: openAiAccount
  name: deploymentName
  sku: {
    name: 'Standard'
    capacity: capacityThousands
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'    // Stable: no surprise model changes in Dev
    raiPolicyName: 'Microsoft.Default'
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

@description('Azure OpenAI account name')
output openAiAccountName string = openAiAccount.name

@description('Azure OpenAI account resource ID — used by the RBAC module in main.bicep')
output openAiAccountId string = openAiAccount.id

@description('Azure OpenAI endpoint — set as AZURE_OPENAI_ENDPOINT in the orchestrator')
output openAiEndpoint string = openAiAccount.properties.endpoint

@description('GPT deployment name — set as AZURE_OPENAI_DEPLOYMENT_NAME in the orchestrator')
output deploymentName string = gptDeployment.name

@description('System-assigned Managed Identity principal ID of the OpenAI account')
output managedIdentityPrincipalId string = openAiAccount.identity.principalId
