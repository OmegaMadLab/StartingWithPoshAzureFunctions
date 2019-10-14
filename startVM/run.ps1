using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Get VM data
$vmName = $Request.Body.vmName
$resourceGroupName = $Request.Body.resourceGroup

if (-not $vmName) {
    $status = [HttpStatusCode]::BadRequest
    $body = "This function expects to be invoked with at least a VM name specified."
} else {
    $vmName = ($vmName).split(".")[0]
    if ($resourceGroupName) {
        Write-Host "Starting VM $vmName in resource group $resourceGroupName..."
        $vm = Get-AzVm -Name $vmName -ResourceGroupName $resourceGroupName        
    } else {
        Write-Host "Looking for $vmName..."
        $vm = Get-AzVm | ? { $_.OsProfile.ComputerName -eq $vmName }
        Write-Host "VM $vmName found in resourceGroup $($vm.ResourceGroupName). Starting it..."
        Write-Host "VM started."
    }
    $vm | Start-AzVM
    Write-Host "VM started."

    $status = [HttpStatusCode]::OK
    $body = "OK"
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})
