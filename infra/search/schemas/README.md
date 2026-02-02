# Unified Index Schema Artifacts

This folder contains the versioned Azure AI Search index schema used to create the unified index via Infrastructure as Code.

- Source of truth: a single JSON file named `metadata-context-index-v1.json`
- The deployment script in `infra/search/main.bicep` consumes this file directly
- No manual configuration in the Azure Portal is used

## Requirements

- The index name is fixed: `metadata-context-index-v1`
- Schema must be complete and match the frozen contract (fields, attributes, vector definitions, semantic configuration)
- Vector fields and semantic configuration must be present (structure only; no embeddings are generated here)

## File

- `metadata-context-index-v1.json` – the exact JSON definition the Azure Search REST API expects for an index resource

Example minimal structure (illustrative only; replace with the frozen schema):

```json
{
  "name": "metadata-context-index-v1",
  "fields": [
    { "name": "id", "type": "Edm.String", "key": true, "filterable": false, "searchable": false }
    // ... other fields from the frozen schema
  ],
  "semantic": {
    "configurations": [
      {
        "name": "semantic-config",
        "prioritizedFields": {
          "titleField": { "fieldName": "title" },
          "contentFields": [ { "fieldName": "description" }, { "fieldName": "suggestedDescription" } ]
        }
      }
    ]
  },
  "vectorSearch": {
    "algorithmConfigurations": [ { "name": "vector-config", "kind": "hnsw" } ],
    "profiles": [ { "name": "default-vector-profile", "algorithm": "vector-config" } ]
  }
}
```

Important: The actual file must reflect the frozen schema exactly (field names, attributes, vector dimensions, and semantic configuration).