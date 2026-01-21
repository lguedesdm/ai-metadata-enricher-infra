# RBAC Validation Guide - Storage Account Dev

Este documento fornece comandos para validar o RBAC aplicado ao Azure Storage Account Dev.

## Informações de Deploy

Após executar o deploy, você terá:
- **Storage Account**: `aimedevst{uniqueString}`
- **Resource Group**: `rg-aime-dev`
- **Managed Identity**: System-Assigned do próprio Storage Account
- **Role Assignment**: Storage Blob Data Contributor

---

## 1. Verificar Role Assignments no Storage Account

### Listar todas as role assignments do Storage Account:

```powershell
az role assignment list \
  --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-aime-dev/providers/Microsoft.Storage/storageAccounts/aimedevst{uniqueString} \
  --output table
```

### Listar role assignments específicas para a Managed Identity do Storage Account:

```powershell
$storageAccountName = "aimedevst{uniqueString}"
$resourceGroup = "rg-aime-dev"

# Obter Principal ID da Managed Identity
$principalId = az storage account show `
  --name $storageAccountName `
  --resource-group $resourceGroup `
  --query "identity.principalId" -o tsv

# Listar role assignments desta identidade
az role assignment list `
  --assignee $principalId `
  --output table
```

---

## 2. Validar Acesso de Leitura

### Testar listagem de containers usando Managed Identity:

```powershell
# Usando Azure CLI com autenticação via Managed Identity (requer login com identidade autorizada)
az storage container list `
  --account-name aimedevst{uniqueString} `
  --auth-mode login `
  --output table
```

**Resultado esperado**: Lista dos 4 containers (synergy, zipline, documentation, schemas)

---

## 3. Validar Acesso de Escrita (Storage Blob Data Contributor)

### Upload de um arquivo de teste:

```powershell
# Criar arquivo de teste
"Test file for RBAC validation" | Out-File -FilePath test-rbac.txt

# Upload para container synergy usando RBAC
az storage blob upload `
  --account-name aimedevst{uniqueString} `
  --container-name synergy `
  --name rbac-validation/test-rbac.txt `
  --file test-rbac.txt `
  --auth-mode login

# Verificar se o upload foi bem-sucedido
az storage blob list `
  --account-name aimedevst{uniqueString} `
  --container-name synergy `
  --prefix rbac-validation/ `
  --auth-mode login `
  --output table
```

**Resultado esperado**: Arquivo `rbac-validation/test-rbac.txt` aparece na listagem

---

## 4. Validar Acesso Negado (Teste Negativo)

### Tentar acessar com usuário sem permissões:

```powershell
# Login com um usuário que NÃO tem role assignment no Storage Account
az login --use-device-code

# Tentar listar containers (deve falhar)
az storage container list `
  --account-name aimedevst{uniqueString} `
  --auth-mode login
```

**Resultado esperado**: Erro de autorização
```
AuthorizationPermissionMismatch: This request is not authorized to perform this operation using this permission.
```

---

## 5. Verificar Configuração de Rede (Deve estar em modo Dev)

### Validar que o acesso público está habilitado:

```powershell
az storage account show `
  --name aimedevst{uniqueString} `
  --resource-group rg-aime-dev `
  --query "{publicNetworkAccess:publicNetworkAccess, allowBlobPublicAccess:allowBlobPublicAccess, networkAcls:networkRuleSet.defaultAction}"
```

**Resultado esperado**:
```json
{
  "allowBlobPublicAccess": false,
  "networkAcls": "Allow",
  "publicNetworkAccess": "Enabled"
}
```

---

## 6. Validar que SAS Tokens e Access Keys NÃO são usados

### Verificar que não há chaves de acesso hardcoded no código:

```powershell
# Buscar no repositório por padrões de Access Keys ou SAS tokens
cd C:\Users\leona\OneDrive\desktop\dm\ai-metadata-enricher-infra
Select-String -Path "infra\**\*.bicep" -Pattern "listKeys|SharedAccessSignature|AccountKey"
```

**Resultado esperado**: Nenhum resultado (RBAC-only)

---

## 7. Informações de Role Definitions

### Storage Blob Data Reader
- **Role ID**: `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`
- **Permissões**: Ler e listar containers e blobs

### Storage Blob Data Contributor
- **Role ID**: `ba92f5b4-2d11-453d-a403-e96b0029c9fe`
- **Permissões**: Ler, escrever e deletar containers e blobs

---

## Comandos Rápidos de Validação

```powershell
# Substituir {uniqueString} pelo valor real do seu Storage Account

# 1. Verificar role assignments
az role assignment list --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-aime-dev/providers/Microsoft.Storage/storageAccounts/aimedevst{uniqueString}

# 2. Listar containers (teste positivo)
az storage container list --account-name aimedevst{uniqueString} --auth-mode login

# 3. Criar blob de teste (teste de escrita)
"RBAC Test" | Out-File test.txt
az storage blob upload --account-name aimedevst{uniqueString} --container-name synergy --name test.txt --file test.txt --auth-mode login

# 4. Limpar arquivo de teste
Remove-Item test.txt
```

---

## Resultado Esperado da Task 3

✅ **RBAC Aplicado**:
- Storage Account Managed Identity tem role `Storage Blob Data Contributor`
- Scope: Storage Account completo
- Autenticação: RBAC-only (sem SAS tokens ou access keys)

✅ **Rede em Modo Dev**:
- `publicNetworkAccess`: `Enabled`
- `networkAcls.defaultAction`: `Allow`
- `allowBlobPublicAccess`: `false` (privado via RBAC)

✅ **Sem Configurações Avançadas**:
- Sem Private Endpoints
- Sem VNet integration
- Sem lifecycle policies adicionais

---

**Data**: Janeiro 2026  
**Ambiente**: Dev  
**Task**: TASK 3 - Apply RBAC, network rules, and access validation
