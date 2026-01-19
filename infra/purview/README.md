# Microsoft Purview Integration

## Overview

This module documents the Microsoft Purview integration requirements for the AI Metadata Enricher platform. 

**IMPORTANT: Purview resources are NOT created by Bicep in this MVP.**  
Purview configuration is managed separately via the Purview portal or dedicated governance workflows.

## Purpose

Microsoft Purview serves as the **governed metadata catalog** for the AI Metadata Enricher platform. The enrichment system will interact with Purview to:

1. **Read** metadata from Purview to enrich and enhance descriptions
2. **Write** AI-generated suggestions to a custom attribute in Purview
3. **Preserve** human governance by never modifying the official "Description" field

---

## Custom Attribute: "Suggested Description"

### Specification

- **Attribute Name**: `suggestedDescription`
- **Type**: String (multi-line text)
- **Scope**: Entity-level attribute (applied to data assets)
- **Writable by**: AI enrichment system (via Managed Identity and RBAC)
- **Read by**: Data stewards, governance teams, and review workflows

### Purpose

This custom attribute holds AI-generated description candidates. Data stewards review these suggestions and manually promote them to the official "Description" field if appropriate.

### Governance Principle

**The AI MUST NEVER write to the official "Description" field.**  
This ensures human oversight and maintains data governance integrity.

---

## Configuration Steps (Manual)

Since Purview resources are not provisioned via Bicep, configure the custom attribute manually:

1. **Navigate to Microsoft Purview Studio**  
   Open the Purview account for your environment.

2. **Go to Data Map > Custom Attributes**  
   Create a new custom attribute:
   - **Name**: `suggestedDescription`
   - **Type**: `String`
   - **Multi-line**: `Yes`
   - **Apply to**: Entity types relevant to your catalog (e.g., datasets, tables, columns)

3. **Grant RBAC Permissions**  
   Assign the following roles to the AI enrichment system's Managed Identity:
   - **Purview Data Curator** (or equivalent custom role with write permissions to custom attributes)
   - Ensure the role explicitly allows writing to `suggestedDescription` but **NOT** to the official `description` field.

4. **Document the Purview Account Connection String**  
   Store the Purview account endpoint (e.g., `https://{purview-account}.purview.azure.com`) in Azure Key Vault or as an environment variable for the compute runtime (future implementation).

---

## Integration Contract

### Read Operations

- The enrichment system reads metadata (titles, existing descriptions, schemas) from Purview to generate suggestions.
- Use Purview REST API or SDK with Managed Identity authentication.

### Write Operations

- The enrichment system writes AI-generated suggestions to the `suggestedDescription` attribute only.
- **Never write to the official `description` field.**
- Use Purview REST API or SDK with Managed Identity authentication.

### Audit Trail

- All Purview write operations must be logged to the Cosmos DB `audit` container.
- Include timestamp, entity ID, suggested description, and AI confidence score.

---

## Future Enhancements (Test/Prod)

- **Automated Review Workflow**: Integrate with Purview's approval workflows to notify data stewards when new suggestions are available.
- **Feedback Loop**: Capture steward feedback (accept/reject) and use it to improve AI suggestions.
- **Private Endpoints**: Secure Purview access via Private Endpoints in Test/Prod environments.
- **Advanced RBAC**: Implement fine-grained RBAC to separate read and write permissions for different components.

---

## References

- [Microsoft Purview Documentation](https://learn.microsoft.com/en-us/purview/)
- [Purview REST API](https://learn.microsoft.com/en-us/rest/api/purview/)
- [Custom Attributes in Purview](https://learn.microsoft.com/en-us/purview/how-to-custom-attributes)

---

**Note**: This documentation serves as a contract for the future compute runtime (Azure Container Apps) that will implement the Purview integration logic.
