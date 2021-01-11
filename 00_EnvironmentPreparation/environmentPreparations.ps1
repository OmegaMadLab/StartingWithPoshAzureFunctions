# !!! Log both PowerShell Az and CLI to your subscription before starting !!!

$rgName="PoshAzFunctionDemo-RG"
$location = "westeurope"

# Get or create a resource group
try {
    $Rg = Get-AzResourceGroup -Name $RgName -ErrorAction Stop
} catch {
    $Rg = New-AzResourceGroup -Name $RgName -Location $Location
}

$subId = (Get-AzContext).Subscription.Id

# Create a Key Vault to host the secrets
# To create a key vault, you must be a member of the AAD tenant; guest account (Microsoft Account or users invited via Azure B2B) are not authorized to interact with vaults.
$keyVault = New-AzKeyVault -Name ("PoshAzFuncDemoKV" + (Get-Random -max 9999999)) `
                -ResourceGroupName $rgName `
                -Location $location `
                -EnablePurgeProtection

Set-AzKeyVaultAccessPolicy -UserPrincipalName (Get-AzContext).Account.Id `
    -PermissionsToSecrets "list","set","get","delete" `
    -VaultName $keyVault.VaultName -PassThru

# Insert the SendGrid API Key - info on account creation available at https://www.omegamadlab.com/2019/10/21/using-sendgrid-binding-from-powershell-in-azure-functions/
$secret = Set-AzKeyVaultSecret -Name "SendGridApiKey" `
            -SecretValue (Read-Host "Insert SendGrid API KEY" -AsSecureString) `
            -VaultName $keyVault.VaultName

# Create an unattached managed disk to test resourceReport function
$diskConfig = New-AzDiskConfig -Location $location `
                -SkuName Standard_LRS `
                -DiskSizeGB 10 `
                -CreateOption Empty

$diskConfig | 
    New-AzDisk -ResourceGroupName $rgName `
    -DiskName "UnattachedDisk"

# Deploy an Azure SQL DB with AdventureWorksLT to test database connectivity from AzFunctions
$sqlSrv = New-AzSqlServer -ServerName ("azsqlsrv" + (Get-Random -Maximum 9999999)) `
            -Location $Location `
            -ResourceGroupName $rgName `
            -SqlAdministratorCredentials (New-Object System.Management.Automation.PSCredential ("dbadmin", (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force)))

New-AzSqlServerFirewallRule -ServerName $sqlSrv.ServerName `
    -AllowAllAzureIPs `
    -ResourceGroupName $rgName

New-AzSqlDatabase -DatabaseName "DemoDB" `
    -ServerName $sqlSrv.ServerName `
    -Edition Basic `
    -ResourceGroupName $rgName `
    -SampleName AdventureWorksLT

# Store SQL credentials in KeyVault
$sqlAdmin = Set-AzKeyVaultSecret -Name "sqlAdmin" `
                -SecretValue (ConvertTo-SecureString "dbadmin" -AsPlainText -Force) `
                -VaultName $keyVault.VaultName

$sqlAdminPwd = Set-AzKeyVaultSecret -Name "sqlAdmin" `
                -SecretValue (ConvertTo-SecureString "Passw0rd.1" -AsPlainText -Force) `
                -VaultName $keyVault.VaultName

# Deploy a simple Windows VM to test vnet integration
$deployment = New-AzResourceGroupDeployment -TemplateUri https://raw.githubusercontent.com/OmegaMadLab/LabTemplates/master/vnet.json `
                -ResourceGroupName $rgName 
                
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
    -sku S1 `
    -hostingPlanName "$siteName-plan" `
    -ResourceGroupName $rgName

# Create a new eventgrid subscription on the resource group for stop/deallocate VM events to trigger the monitoring webapp
$AdvFilter=@{operator="StringContains"; key="data.operationName"; Values=@('Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/powerOff/action')}

New-AzEventGridSubscription `
  -EventSubscriptionName ("demoSubToResourceGroupAzFunc" + (Get-Random -max 9999999)) `
  -ResourceGroupName $rgName `
  -Endpoint "https://$siteName.azurewebsites.net/api/updates" `
  -IncludedEventType "Microsoft.Resources.ResourceActionSuccess" `
  -AdvancedFilter $AdvFilter

### Function Apps creation cycle ###
$functionAppNames = @()
$functionAppNames += ("AzureFunctionDemo-consumption-" + (Get-Random -max 999999999))
$functionAppNames += ("AzureFunctionDemo-dedicated-" + (Get-Random -max 999999999))

foreach ($functionAppName in $functionAppNames) {
    # Create storage account
    $storAccnt = New-AzStorageAccount -Name ("poshazfuncdemo" + (Get-Random -Max 99999999)) -ResourceGroupName $rgName -SkuName Standard_LRS -Location $location
    
    # Create a storage queue
    $storQueue = $storAccnt | New-AzStorageQueue -Name "vmtoprocess"

    if($functionAppName -like '*consumption*') {
        # Create function app on consumption plan
        $funcApp = New-AzFunctionApp -ResourceGroupName $rgName `
                        -Name $functionAppName `
                        -Location 'westeurope' `
                        -OSType 'Windows' `
                        -Runtime 'PowerShell' `
                        -StorageAccountName $storAccnt.StorageAccountName `
                        -FunctionsVersion '3' `
                        -RuntimeVersion '7.0' `
                        -IdentityType 'SystemAssigned'

    } else {
        # Create a function app on dedicated plan used also for monitoring webapp

        $funcApp = New-AzFunctionApp -ResourceGroupName $rgName `
                    -Name $functionAppName `
                    -OSType 'Windows' `
                    -Runtime 'PowerShell' `
                    -StorageAccountName $storAccnt.StorageAccountName `
                    -FunctionsVersion '3' `
                    -RuntimeVersion '7.0' `
                    -PlanName "$siteName-plan"`
                    -IdentityType 'SystemAssigned'

    }
    
    # Assign the contributor role on the RG to the system assigned managed identity
    New-AzRoleAssignment -ResourceGroupName $rgName `
        -RoleDefinitionName "Contributor" `
        -ObjectId $funcApp.IdentityPrincipalId

    # Adding an Access Policy on the KeyVault for the Function system assigned managed identity
    Set-AzKeyVaultAccessPolicy -ObjectId $funcApp.IdentityPrincipalId `
        -PermissionsToSecrets "get" `
        -VaultName $keyVault.VaultName `
        -PassThru

    # Adding AppSetting for:
    # - storage queue name
    # - SendGrid API Key, using a Key Vault secret
    # - recipient e-mail address for scheduled report
    # - timezone for the timer trigger
    # - Azure SQL logical server URI and credentials, using Key Vault secrets
    $appSettings = @{
        "StorageQueueName" = "$($storQueue.Name)";
        "AzureWebJobsSendGridApiKey" = "@Microsoft.KeyVault(SecretUri=$($secret.Id)^^)";
        "ToMailAddress" = "$(Read-Host "Insert your mail address")";
        "WEBSITE_TIME_ZONE" = "W. Europe Standard Time";
        "sqlServer" = "$($sqlSrv.FullyQualifiedDomainName)";
        "SqlAdmin" = "@Microsoft.KeyVault(SecretUri=$($sqlAdmin.Id)^^)";
        "SqlAdminPwd" = "@Microsoft.KeyVault(SecretUri=$($sqlAdminPwd.Id)^^)";
    }

    $funcApp | Update-AzFunctionAppSetting -AppSetting $appSettings

}

# applying custom configurations on dedicated plan
$functionAppName = (Get-AzFunctionApp -ResourceGroupName $rgName | ? Name -like '*dedicated*').Name

# Configure integration with GitHub repo
az functionapp deployment source config `
    --branch wip `
    --name $functionAppName `
    --repo-url https://github.com/OmegaMadLab/StartingWithPoshAzureFunctions `
    --resource-group $rgName `
    --manual-integration

# Enable concurrency for PowerShell workers - may lead to timeouts with consumption plan
Update-AzFunctionAppSetting -ResourceGroupName $rgName `
    -Name $functionAppName `
    -AppSetting @{"PSWorkerInProcConcurrencyUpperBound"= 10}

# Create a new eventgrid subscription on the resource group for stop/deallocate VM events to trigger restartVM-EventGrid function
# Endpoint for Function App requires system key, that can be obtained with API call with master key. Master key can be obtained from AppSettings.
# Replace {masterkey} with your function App Master Key
$systemKey = Invoke-RestMethod -Method Get -Uri http://$functionAppName.azurewebsites.net/admin/host/systemkeys/eventgrid_extension?code={masterkey}

$AdvFilter=@{operator="StringContains"; key="data.operationName"; Values=@('Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/powerOff/action')}

New-AzEventGridSubscription `
  -EventSubscriptionName ("demoSubToResourceGroupAzFunc" + (Get-Random -max 9999999)) `
  -ResourceGroupName $rgName `
  -Endpoint "https://$functionAppName.azurewebsites.net/runtime/webhooks/eventgrid?functionName=restartVM-EventGrid&code=$($systemKey.value)" `
  -IncludedEventType "Microsoft.Resources.ResourceActionSuccess" `
  -AdvancedFilter $AdvFilter

