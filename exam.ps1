# deploy_fixed.ps1
#region variables
$STAFF_CODE = "SD6127"
$LOCATION = "eastus2"              
$SUBSCRIPTION_ID = (az account show --query id -o tsv)
$RG_NAME = "rg-$STAFF_CODE-container-apps"
$VNET_NAME = "vnet-$STAFF_CODE"
$SUBNET_CONTAINER_NAME = "snet-container"
$SUBNET_AGW_NAME = "snet-agw"
$MANAGED_IDENTITY_NAME = "id-$STA_CODE" -replace '\$','SD6127'  # ensure correct name if copy/paste; or use below exact
$MANAGED_IDENTITY_NAME = "id-$STAFF_CODE"
$CONTAINER_APP_ENV = "env-$STAFF_CODE"
$CONTAINER_APP_NAME = "app-$STAFF_CODE"
$STORAGE_ACCOUNT_NAME = ("st{0}" -f $STAFF_CODE).ToLower()
$DB_SERVER_NAME = "sql-$STAFF_CODE"
$DB_NAME = "simplcommerce"
$AGW_NAME = "agw-$STAFF_CODE"
$AGW_PIP_NAME = "pip-$STAFF_CODE-agw"
$LA_NAME = "laworkspace-$STAFF_CODE"
#endregion

function Wait-ProviderRegistered($provider) {
    Write-Host "Registering provider $provider ..."
    az provider register -n $provider --wait | Out-Null
    $status = az provider show -n $provider --query "registrationState" -o tsv
    if ($status -ne "Registered") {
        throw "Provider $provider not registered (status: $status)"
    }
    Write-Host "$provider registered."
}

# ensure correct subscription
az account set --subscription $SUBSCRIPTION_ID

# register required providers
$providers = @("Microsoft.App","Microsoft.OperationalInsights","Microsoft.Insights","Microsoft.Storage","Microsoft.Sql","Microsoft.Network")
foreach ($p in $providers) { Wait-ProviderRegistered $p }

# 1. Create Resource Group
az group create --name $RG_NAME --location $LOCATION | Write-Output

# 2. Create Virtual Network and Subnets
az network vnet create `
  --name $VNET_NAME `
  --resource-group $RG_NAME `
  --location $LOCATION `
  --address-prefix "10.0.0.0/16" | Write-Output

az network vnet subnet create `
  --resource-group $RG_NAME `
  --vnet-name $VNET_NAME `
  --name $SUBNET_CONTAINER_NAME `
  --address-prefix "10.0.0.0/23" `
  --disable-private-endpoint-network-policies true | Write-Output

az network vnet subnet create `
  --resource-group $RG_NAME `
  --vnet-name $VNET_NAME `
  --name $SUBNET_AGW_NAME `
  --address-prefix "10.0.2.0/24" | Write-Output

# 3. Create User-assigned Managed Identity
$identity = az identity create `
  --name $MANAGED_IDENTITY_NAME `
  --resource-group $RG_NAME `
  --location $LOCATION | ConvertFrom-Json

$IDENTITY_PRINCIPAL_ID = $identity.principalId
$IDENTITY_ID = $identity.id

# 4. Create Storage Account
az storage account create `
  --name $STORAGE_ACCOUNT_NAME `
  --resource-group $RG_NAME `
  --location $LOCATION `
  --sku Standard_LRS `
  --kind StorageV2 `
  --https-only true | Write-Output

# Wait for storage account to exist and keys to be ready (retry loop)
$maxAttempts = 12
$attempt = 0
while ($attempt -lt $maxAttempts) {
  try {
    $acct = az storage account show --name $STORAGE_ACCOUNT_NAME --resource-group $RG_NAME -o json 2>$null | ConvertFrom-Json
    if ($acct -ne $null) { break }
  } catch {}
  Start-Sleep -Seconds 10
  $attempt++
  Write-Host "Waiting for storage account to be ready... attempt $attempt/$maxAttempts"
}
if ($acct -eq $null) { throw "Storage account $STORAGE_ACCOUNT_NAME not found after wait." }

# Get key after confirmed existence
$storageKey = az storage account keys list --account-name $STORAGE_ACCOUNT_NAME --resource-group $RG_NAME --query '[0].value' -o tsv

# Give managed identity Storage Blob Data Contributor role (specify assignee type)
$storageScope = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
az role assignment create `
  --assignee-object-id $IDENTITY_PRINCIPAL_ID `
  --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" `
  --scope $storageScope | Write-Output

# 5. Create Azure SQL Server & DB (use eastus2 to avoid region limit)
# NOTE: change admin password to secure secret retrieval in production
$adminPwd = "YourStrongPassword123!"
try {
  $sqlCreate = az sql server create `
    --name $DB_SERVER_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --admin-user "sqladmin" `
    --admin-password $adminPwd -o json 2>&1 | ConvertFrom-Json
  if (-not $sqlCreate.id) { throw "SQL server create returned no id; check error." }

  az sql db create `
    --name $DB_NAME `
    --resource-group $RG_NAME `
    --server $DB_SERVER_NAME `
    --service-objective Basic | Write-Output
} catch {
  Write-Error "SQL create failed: $_"
  throw "Aborting due to SQL create failure. Pre-create SQL server manually or pick a supported region."
}

# 6. Create Public IP for Application Gateway
az network public-ip create `
  --resource-group $RG_NAME `
  --name $AGW_PIP_NAME `
  --sku Standard `
  --allocation-method Static `
  --version IPv4 | Write-Output

# 7. Create Application Gateway (provide minimal required fields incl. priority)
try {
  az network application-gateway create `
    --name $AGW_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --vnet-name $VNET_NAME `
    --subnet $SUBNET_AGW_NAME `
    --public-ip-address $AGW_PIP_NAME `
    --sku Standard_v2 `
    --capacity 2 `
    --frontend-port 80 `
    --http-settings-port 80 `
    --priority 100 | Write-Output
} catch {
  Write-Warning "Application Gateway create failed: $_"
}

# 8. Create Log Analytics workspace BEFORE Container Apps env
az monitor log-analytics workspace create `
  --resource-group $RG_NAME `
  --workspace-name $LA_NAME `
  --location $LOCATION | Write-Output

# Get workspace id and key
$LA_CUSTOMER_ID = az monitor log-analytics workspace show --resource-group $RG_NAME --workspace-name $LA_NAME --query customerId -o tsv
$LA_KEY = az monitor log-analytics workspace get-shared-keys --resource-group $RG_NAME --workspace-name $LA_NAME --query primarySharedKey -o tsv

Write-Host "Creating Container Apps Environment..."
# 9. Create Container Apps Environment (requires workspace and registered provider)
az containerapp env create `
  --name $CONTAINER_APP_ENV `
  --resource-group $RG_NAME `
  --location $LOCATION `
  --infrastructure-subnet-resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_CONTAINER_NAME" `
  --logs-workspace-id $LA_CUSTOMER_ID `
  --logs-workspace-key $LA_KEY

# Wait for environment to be ready
Start-Sleep -Seconds 60

# 10. Deploy Container App (get storage key for env var)
Write-Host "Waiting for Container Apps Environment to be ready..."
$maxAttempts = 12
$attempt = 0
$envReady = $false

while ($attempt -lt $maxAttempts -and -not $envReady) {
    try {
        $env = az containerapp env show --name $CONTAINER_APP_ENV --resource-group $RG_NAME 2>$null
        if ($env) {
            $envReady = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 30
    $attempt++
    Write-Host "Checking Container Apps Environment... attempt $attempt/$maxAttempts"
}

if (-not $envReady) {
    throw "Container Apps Environment not ready after waiting. Please check the environment status in the portal."
}

Write-Host "Getting storage key..."
$storageKey = az storage account keys list --account-name $STORAGE_ACCOUNT_NAME --resource-group $RG_NAME --query '[0].value' -o tsv

Write-Host "Creating Container App..."
az containerapp create `
  --name $CONTAINER_APP_NAME `
  --resource-group $RG_NAME `
  --environment $CONTAINER_APP_ENV `
  --image "simplcommerce/simplcommercedemo:latest" `
  --target-port 80 `
  --ingress external `
  --user-assigned $IDENTITY_ID `
  --env-vars "ConnectionStrings__DefaultConnection=Server=tcp:$DB_SERVER_NAME.database.windows.net;Database=$DB_NAME;Authentication=Active Directory Default;TrustServerCertificate=True" "AzureStorage__ConnectionString=DefaultEndpointsProtocol=https;AccountName=$STORAGE_ACCOUNT_NAME;AccountKey=$storageKey;EndpointSuffix=core.windows.net"

# Wait for Container App to be ready
Start-Sleep -Seconds 60

# 11. Configure Application Gateway backend pool only if container app FQDN exists
$CONTAINER_APP_FQDN = az containerapp show --name $CONTAINER_APP_NAME --resource-group $RG_NAME --query properties.configuration.ingress.fqdn -o tsv

if ([string]::IsNullOrEmpty($CONTAINER_APP_FQDN)) {
    Write-Warning "Container App FQDN not available. Skipping AG backend pool creation. If you want AG in front, configure backend pool manually once FQDN is ready."
} else {
    az network application-gateway address-pool create `
      --gateway-name $AGW_NAME `
      --resource-group $RG_NAME `
      --name "containerapp-pool" `
      --servers $CONTAINER_APP_FQDN | Write-Output

    # Create http-settings and listener and rule - ensure priority is provided
    az network application-gateway http-settings create `
      --gateway-name $AGW_NAME `
      --resource-group $RG_NAME `
      --name "containerapp-http-settings" `
      --port 80 `
      --protocol Http | Write-Output

    # create listener (if not exists)
    az network application-gateway http-listener create `
      --gateway-name $AGW_NAME `
      --resource-group $RG_NAME `
      --name "containerapp-listener" `
      --frontend-port 80 `
      --frontend-ip "appGatewayFrontendIP" | Out-Null

    # create rule (NOTE: priority is required)
    az network application-gateway rule create `
      --gateway-name $AGW_NAME `
      --resource-group $RG_NAME `
      --name "containerapp-rule" `
      --address-pool "containerapp-pool" `
      --http-settings "containerapp-http-settings" `
      --http-listener "containerapp-listener" `
      --priority 100 | Write-Output
}

Write-Host "Deployment script finished. Check outputs and portal for resources."
