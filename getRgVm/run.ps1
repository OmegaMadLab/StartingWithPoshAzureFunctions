using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$rgName = $Request.Query.resourcegroup
if (-not $rgName) {
    $rgName = $Request.Body.resourcegroup
}

$action = $Request.Query.action
if (-not $action) {
    $action = $Request.Body.action
}

if ($rgName -and (($action -eq "start") -or ($action -eq "stop"))) {

    try {
        Write-Information "Looking for VMs in resource group $rgName..."
        $vm = Get-AzVm -ResourceGroupName $rgName
        
        $vm | ForEach-Object {
            Write-Information "Found VM $($_.Name)."
            # Write RG, VM name and action in queue
            @{
                resourceGroupName = $_.ResourceGroupName
                vmName = $_.Name
                action = $action
            } | Push-OutputBinding -Name outputQueueItem
        }

        $status = [HttpStatusCode]::OK
        $body = "Request correctly processed."
    }
    catch {
        Write-Error $_
        $status = [HttpStatusCode]::BadRequest
        $body = "Error while processing request."
    }
}
else {
    $status = [HttpStatusCode]::BadRequest
    $body = "Please pass a resource group name and a start/stop action on the query string or in the request body."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})
