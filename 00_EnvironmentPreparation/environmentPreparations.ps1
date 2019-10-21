# !!! Log both PowerShell Az and CLI to your subscription before starting !!!

$rgName="PoshAzureDemo2"
$location = "westeurope"

# Get or create resource group
try {
    $Rg = Get-AzResourceGroup -Name $RgName -ErrorAction Stop
} catch {
    $Rg = New-AzResourceGroup -Name $RgName -Location $Location
}

# Get or create storage account
$storAccnt = Get-AzStorageAccount -ResourceGroupName $RgName
if(!$storAccnt) {
    $storAccnt = New-AzStorageAccount -Name ("poshazfuncdemo" + (Get-Random -Max 99999999)) -ResourceGroupName $rgName -SkuName Standard_LRS -Location $location
}
 
$functionAppName = ("AzureFunctionDemo-consumption-" + (Get-Random -max 999999999))
$subId = (Get-AzContext).Subscription.Id

az functionapp create --name $functionAppName `
    --resource-group $RgName `
    --os-type Windows  `
    --runtime Powershell `
    --storage-account $storAccnt.StorageAccountName `
    --consumption-plan-location $location 

az functionapp identity assign --name $functionAppName `
    --resource-group $rgName `
    --role "Contributor" `
    --scope "/subscriptions/$subId/resourceGroups/$rgName"

# To create a key vault, you must be a member of the AAD tenant; guest account (Microsoft Account or users invited via Azure B2B) are not authorized to interact with vaults.
$keyVault = New-AzKeyVault -Name PoshAzFuncDemoKeyVault -ResourceGroupName $rgName -Location $location
Set-AzKeyVaultAccessPolicy -UserPrincipalName (Get-AzContext).Account.Id -PermissionsToSecrets "set","get","delete" -VaultName $keyVault.VaultName -PassThru

# Adding an Access Policy for Function managed identity
$managedId = (Get-AzWebApp -Name $functionAppName -ResourceGroupName $rgName).Identity.PrincipalId
Set-AzKeyVaultAccessPolicy -ObjectId $managedId -PermissionsToSecrets "get" -VaultName $keyVault.VaultName -PassThru

$secret = Set-AzKeyVaultSecret -Name "SendGridApiKey" -SecretValue (Read-Host "Insert SendGrid API KEY" -AsSecureString) -VaultName $keyVault.VaultName

# Adding SendGrid API Key to Function App by referencing KeyVault
az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "AzureWebJobsSendGridApiKey=@Microsoft.KeyVault(SecretUri=$($secret.Id)^^)"

# Setting timezone for timer trigger
az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "WEBSITE_TIME_ZONE=W. Europe Standard Time"

# Create an unattached managed disk to test resourceReport function
$diskConfig = New-AzDiskConfig -Location  $location -SkuName Standard_LRS -DiskSizeGB 10 -CreateOption Empty 
$diskConfig | New-AzDisk -ResourceGroupName $rgName -DiskName "UnattachedDisk"

# Setting recipient email address for scheduled report
az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "ToMailAddress=$(Read-Host "Insert your mail address")"

    $sqlSrv = New-AzSqlServer -ServerName ("azsqlsrv" + (Get-Random -Maximum 9999999)) `
    -Location $Location `
    -ResourceGroupName $Rg.ResourceGroupName `
    -SqlAdministratorCredentials (New-Object System.Management.Automation.PSCredential ($domainAdmin, $domainAdminPwd))

# Deploy an Azure SQL DB with AdventureWorksLT to test database connectivity from AzFunctions
$sqlSrv = New-AzSqlServer -ServerName ("azsqlsrv" + (Get-Random -Maximum 9999999)) `
            -Location $Location `
            -ResourceGroupName $rgName `
            -SqlAdministratorCredentials (New-Object System.Management.Automation.PSCredential ("dbadmin", (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force)))

New-AzSqlServerFirewallRule -ServerName $sqlSrv.ServerName -AllowAllAzureIPs -ResourceGroupName $rgName

New-AzSqlDatabase -DatabaseName "DemoDB" `
-ServerName $sqlSrv.ServerName `
-Edition Free `
-ResourceGroupName $rgName `
-SampleName AdventureWorksLT

az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "sqlServer=$($sqlSrv.FullyQualifiedDomainName)"

$sqlAdmin = Set-AzKeyVaultSecret -Name "sqlAdmin" -SecretValue (ConvertTo-SecureString "dbadmin" -AsPlainText -Force) -VaultName $keyVault.VaultName
$sqlAdminPwd = Set-AzKeyVaultSecret -Name "sqlAdmin" -SecretValue (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force) -VaultName $keyVault.VaultName

az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "SqlAdmin=@Microsoft.KeyVault(SecretUri=$($sqlAdmin.Id)^^)"

az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "SqlAdminPwd=@Microsoft.KeyVault(SecretUri=$($sqlAdminPwd.Id)^^)"

# Deploy a simple Windows VM to test vnet integration
$deployment = New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/OmegaMadLab/LabTemplates/master/vnet.json -ResourceGroupName $rgName
                
New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/OmegaMadLab/LabTemplates/master/WinVm.json `
    -envPrefix "Demo" `
    -vmName "WinVM" `
    -subnetid $deployment.Outputs.subnetId.Value `
    -adminUserName "localAdmin" `
    -adminPassword (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force) `
    -ResourceGroupName $rgName

# Get or create resource group
try {
    $Rg = Get-AzResourceGroup -Name "premiumPlan-RG" -ErrorAction Stop
} catch {
    $Rg = New-AzResourceGroup -Name "premiumPlan-RG" -Location $Location
}

az functionapp plan create --resource-group ($Rg).ResourceGroupName --name PremiumConsumptionPlan `
    --location $location --sku EP1

Move-AzResource -DestinationResourceGroupName $rg.ResourceGroupName -ResourceId (Get-AzWebApp -Name $functionAppName -ResourceGroupName $rgName).Id

az functionapp update --name $functionAppName --resource-group $rg.ResourceGroupName --plan "/subscriptions/bf51af6a-bb5b-4406-b067-3eb3a401281b/resourceGroups/premiumPlan-RG/providers/Microsoft.Web/serverfarms/PremiumConsumptionPlan"