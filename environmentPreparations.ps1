# !!! Log both PowerShell Az and CLI to your subscription before starting !!!

$rgName="PoshAzureDemo"
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
 
$functionName = ("AzureFunctionDemo-consumption-" + (Get-Random -max 999999999))
$subId = (Get-AzContext).Subscription.Id

az functionapp create --name $functionName `
    --resource-group $RgName `
    --os-type Windows  `
    --runtime Powershell `
    --storage-account $storAccnt.StorageAccountName `
    --consumption-plan-location $location `

az functionapp identity assign --name $functionName `
    --resource-group $rgName `
    --role contributor `
    --scope "/subscriptions/$subId/$rgName"
    
