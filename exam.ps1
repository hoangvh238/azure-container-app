# Variables
$STAFF_CODE="SD6127"
$LOCATION="eastus"
$RG_NAME="rg-$STAFF_CODE-container-apps"
$VNET_NAME="vnet-$STAFF_CODE"
$SUBNET_CONTAINER_NAME="snet-container"
$SUBNET_AGW_NAME="snet-agw"
$MANAGED_IDENTITY_NAME="id-$STAFF_CODE"
$CONTAINER_APP_ENV="env-$STAFF_CODE"
$CONTAINER_APP_NAME="app-$STAFF_CODE"
$STORAGE_ACCOUNT_NAME="st${STAFF_CODE}".ToLower()
$DB_SERVER_NAME="sql-$STAFF_CODE"
$DB_NAME="simplcommerce"
$AGW_NAME="agw-$STAFF_CODE"
$AGW_PIP_NAME="pip-$STAFF_CODE-agw"

# 1. Create Resource Group
az group create --name $RG_NAME --location $LOCATION

# 2. Create Virtual Network and Subnets
az network vnet create `
    --name $VNET_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --address-prefix "10.0.0.0/16"

# Create subnet for Container Apps (needs /23 or larger)
az network vnet subnet create `
    --resource-group $RG_NAME `
    --vnet-name $VNET_NAME `
    --name $SUBNET_CONTAINER_NAME `
    --address-prefix "10.0.0.0/23"

# Create subnet for Application Gateway
az network vnet subnet create `
    --resource-group $RG_NAME `
    --vnet-name $VNET_NAME `
    --name $SUBNET_AGW_NAME `
    --address-prefix "10.0.2.0/24"

# 3. Create User-assigned Managed Identity
az identity create `
    --name $MANAGED_IDENTITY_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION

# Get the identity's principal ID
$IDENTITY_PRINCIPAL_ID = az identity show --name $MANAGED_IDENTITY_NAME --resource-group $RG_NAME --query principalId -o tsv
$IDENTITY_ID = az identity show --name $MANAGED_IDENTITY_NAME --resource-group $RG_NAME --query id -o tsv

# 4. Create Storage Account
az storage account create `
    --name $STORAGE_ACCOUNT_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --sku Standard_LRS

# Assign RBAC role to managed identity for storage account
az role assignment create `
    --assignee $IDENTITY_PRINCIPAL_ID `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

# 5. Create Azure SQL Database
az sql server create `
    --name $DB_SERVER_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --admin-user "sqladmin" `
    --admin-password "YourStrongPassword123!"

az sql db create `
    --name $DB_NAME `
    --resource-group $RG_NAME `
    --server $DB_SERVER_NAME `
    --service-objective Basic

# 6. Create Application Gateway
# Create Public IP for Application Gateway
az network public-ip create `
    --resource-group $RG_NAME `
    --name $AGW_PIP_NAME `
    --sku Standard `
    --version IPv4

# Create Application Gateway
az network application-gateway create `
    --name $AGW_NAME `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --vnet-name $VNET_NAME `
    --subnet $SUBNET_AGW_NAME `
    --public-ip-address $AGW_PIP_NAME `
    --sku Standard_v2

# 7. Create Container Apps Environment
az containerapp env create `
    --name $CONTAINER_APP_ENV `
    --resource-group $RG_NAME `
    --location $LOCATION `
    --infrastructure-subnet-resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_CONTAINER_NAME"

# 8. Deploy SimplCommerce Container App
az containerapp create `
    --name $CONTAINER_APP_NAME `
    --resource-group $RG_NAME `
    --environment $CONTAINER_APP_ENV `
    --image "simplcommerce/simplcommercedemo:latest" `
    --target-port 80 `
    --ingress external `
    --user-assigned $IDENTITY_ID `
    --env-vars "ConnectionStrings__DefaultConnection=Server=tcp:$DB_SERVER_NAME.database.windows.net;Database=$DB_NAME;Authentication=Active Directory Default;TrustServerCertificate=True" `
    "AzureStorage__ConnectionString=DefaultEndpointsProtocol=https;AccountName=$STORAGE_ACCOUNT_NAME;AccountKey=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME --resource-group $RG_NAME --query '[0].value' -o tsv);EndpointSuffix=core.windows.net"

# 9. Configure Application Gateway backend pool with Container App
$CONTAINER_APP_FQDN = az containerapp show --name $CONTAINER_APP_NAME --resource-group $RG_NAME --query properties.configuration.ingress.fqdn -o tsv

az network application-gateway address-pool create `
    --gateway-name $AGW_NAME `
    --resource-group $RG_NAME `
    --name "containerapp-pool" `
    --servers $CONTAINER_APP_FQDN

# Configure HTTP settings
az network application-gateway http-settings create `
    --gateway-name $AGW_NAME `
    --resource-group $RG_NAME `
    --name "containerapp-http-settings" `
    --port 80 `
    --protocol Http

# Add routing rule
az network application-gateway rule create `
    --gateway-name $AGW_NAME `
    --resource-group $RG_NAME `
    --name "containerapp-rule" `
    --address-pool "containerapp-pool" `
    --http-settings "containerapp-http-settings" `
    --http-listener "containerapp-listener" `
    --priority 100

Write-Host "Deployment completed! Please take screenshots of the Azure Portal showing the deployed resources."
