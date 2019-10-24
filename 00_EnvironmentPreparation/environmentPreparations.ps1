# !!! Log both PowerShell Az and CLI to your subscription before starting !!!

$rgName="PoshAzFunctionDemo-RG"
$location = "westeurope"

# Get or create resource group
try {
    $Rg = Get-AzResourceGroup -Name $RgName -ErrorAction Stop
} catch {
    $Rg = New-AzResourceGroup -Name $RgName -Location $Location
}

$subId = (Get-AzContext).Subscription.Id

# Create a Key Vault to host secrets
# To create a key vault, you must be a member of the AAD tenant; guest account (Microsoft Account or users invited via Azure B2B) are not authorized to interact with vaults.
$keyVault = New-AzKeyVault -Name PoshAzFuncDemoKeyVault -ResourceGroupName $rgName -Location $location
Set-AzKeyVaultAccessPolicy -UserPrincipalName (Get-AzContext).Account.Id -PermissionsToSecrets "set","get","delete" -VaultName $keyVault.VaultName -PassThru

# Insert SendGrid API Key - info on account creation available at http://www.omegamadlab.com/2019/10/21/using-sendgrid-binding-from-powershell-in-azure-functions/
$secret = Set-AzKeyVaultSecret -Name "SendGridApiKey" -SecretValue (Read-Host "Insert SendGrid API KEY" -AsSecureString) -VaultName $keyVault.VaultName

# Create an unattached managed disk to test resourceReport function
$diskConfig = New-AzDiskConfig -Location  $location -SkuName Standard_LRS -DiskSizeGB 10 -CreateOption Empty 
$diskConfig | New-AzDisk -ResourceGroupName $rgName -DiskName "UnattachedDisk"

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

# Store SQL credentials in KeyVault
$sqlAdmin = Set-AzKeyVaultSecret -Name "sqlAdmin" -SecretValue (ConvertTo-SecureString "dbadmin" -AsPlainText -Force) -VaultName $keyVault.VaultName
$sqlAdminPwd = Set-AzKeyVaultSecret -Name "sqlAdmin" -SecretValue (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force) -VaultName $keyVault.VaultName

# Deploy a simple Windows VM to test vnet integration
$deployment = New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/OmegaMadLab/LabTemplates/master/vnet.json -ResourceGroupName $rgName
                
New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/OmegaMadLab/LabTemplates/master/WinVm.json `
    -envPrefix "Demo" `
    -vmName "WinVM" `
    -subnetid $deployment.Outputs.subnetId.Value `
    -adminUserName "localAdmin" `
    -adminPassword (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force) `
    -ResourceGroupName $rgName

Get-AzVm -Name "Demo-WinVM" -ResourceGroupName $rgName | Invoke-AzVMRunCommand -CommandId RunPowerShellScript -ScriptPath .\prepareIIS.ps1

# deploy a monitoring webapp that can help you tracking event grid subscription events
$siteName = "EventGridMonitor-" + (Get-Random -max 999999999)
New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/Azure-Samples/azure-event-grid-viewer/master/azuredeploy.json `
    -siteName $siteName `
    -hostingPlanName "$siteName-plan" `
    -ResourceGroupName $rgName

# Create a new eventgrid subscription on the resource group for stop/deallocate VM events to trigger the monitoring webapp
$AdvFilter=@{operator="StringContains"; key="data.operationName"; Values=@('Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/powerOff/action')}

New-AzEventGridSubscription `
  -EventSubscriptionName demoSubToResourceGroupAzFunc `
  -ResourceGroupName $rgName `
  -Endpoint "https://$siteName.azurewebsites.net/api/updates" `
  -IncludedEventType "Microsoft.Resources.ResourceActionSuccess" `
  -AdvancedFilter $AdvFilter

### Function Apps creation cycle ###
$functionAppNames = @()
$functionAppNames += ("AzureFunctionDemo-consumption-" + (Get-Random -max 999999999))
$functionAppNames += ("AzureFunctionDemo-dedicated-" + (Get-Random -max 999999999))

foreach ($functionAppName in $functionAppNames) {
    # Get or create storage account
    $storAccnt = Get-AzStorageAccount -ResourceGroupName $RgName
    if(!$storAccnt) {
        $storAccnt = New-AzStorageAccount -Name ("poshazfuncdemo" + (Get-Random -Max 99999999)) -ResourceGroupName $rgName -SkuName Standard_LRS -Location $location
    }

    # Create a storage queue
    $storQueue = $storAccnt | New-AzStorageQueue -Name "vmtoprocess"

    if($functionAppName -like '*consumption*') {
        # Create function app
        az functionapp create --name $functionAppName `
            --resource-group $RgName `
            --os-type Windows  `
            --runtime Powershell `
            --storage-account $storAccnt.StorageAccountName `
            --consumption-plan-location $location
    } else {
        $planName = "$functionAppName-plan"

        az functionapp plan create --name $planName `
            --resource-group $RgName `
            --is-linux false `
            --sku S2

        az functionapp create --name $functionAppName `
            --resource-group $RgName `
            --os-type Windows  `
            --runtime Powershell `
            --storage-account $storAccnt.StorageAccountName `
            --plan $planName
    }
    
    # Assign a managed identity and add contributor permission on RG
    az functionapp identity assign --name $functionAppName `
        --resource-group $rgName `
        --role "Contributor" `
        --scope "/subscriptions/$subId/resourceGroups/$rgName"

    # Adding an Access Policy on KeyVault for Function managed identity
    $managedId = (Get-AzWebApp -Name $functionAppName -ResourceGroupName $rgName).Identity.PrincipalId
    Set-AzKeyVaultAccessPolicy -ObjectId $managedId -PermissionsToSecrets "get" -VaultName $keyVault.VaultName -PassThru

    # Adding AppSetting for storage queue name
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "StorageQueueName=$($storQueue.Name)"

    # Adding SendGrid API Key to Function App by referencing KeyVault
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "AzureWebJobsSendGridApiKey=@Microsoft.KeyVault(SecretUri=$($secret.Id)^^)"

    # Setting recipient email address for scheduled report
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "ToMailAddress=$(Read-Host "Insert your mail address")"

    # Setting timezone for timer trigger
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "WEBSITE_TIME_ZONE=W. Europe Standard Time"

    # Adding AppSettings for SQL url and credentials
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "sqlServer=$($sqlSrv.FullyQualifiedDomainName)"

    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "SqlAdmin=@Microsoft.KeyVault(SecretUri=$($sqlAdmin.Id)^^)"
    
    az functionapp config appsettings set -n $functionAppName -g $rgName `
        --settings "SqlAdminPwd=@Microsoft.KeyVault(SecretUri=$($sqlAdminPwd.Id)^^)"

    # Configure integration with GitHub repo
    az functionapp deployment source config `
        --branch master `
        --name $functionAppName `
        --repo-url https://github.com/OmegaMadLab/StartingWithPoshAzureFunctions `
        --resource-group $rgName
}

# applying custom configurations on dedicated plan
$functionAppName = (Get-AzWebApp -ResourceGroupName $rgName | ? Name -like '*dedicated*').Name

# Enable concurrency for PowerShell workers - may lead to timeouts with consumption plan
az functionapp config appsettings set -n $functionAppName -g $rgName `
    --settings "PSWorkerInProcConcurrencyUpperBound=10"

# Create a new eventgrid subscription on the resource group for stop/deallocate VM events to trigger restartVM-EventGrid function
# Endpoint for Function App requires system key, that can be obtained with API call with master key. Master key can be obtained from AppSettings.
# Replace {masterkey} with your function App Master Key
$systemKey = Invoke-RestMethod -Method Get -Uri http://$functionAppName.azurewebsites.net/admin/host/systemkeys/eventgrid_extension?code={masterkey}

$AdvFilter=@{operator="StringContains"; key="data.operationName"; Values=@('Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/powerOff/action')}

New-AzEventGridSubscription `
  -EventSubscriptionName demoSubToResourceGroupAzFunc `
  -ResourceGroupName $rgName `
  -Endpoint "https://$functionAppName.azurewebsites.net/runtime/webhooks/eventgrid?functionName=restartVM-EventGrid&code=$($systemKey.value)" `
  -IncludedEventType "Microsoft.Resources.ResourceActionSuccess" `
  -AdvancedFilter $AdvFilter

