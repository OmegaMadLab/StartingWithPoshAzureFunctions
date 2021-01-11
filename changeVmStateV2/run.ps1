using namespace System.Net

# Input bindings are passed in via param block.
param([System.Object] $QueueItem, $TriggerMetadata)

# Extract info from input binding
$rgName = $QueueItem.resourceGroupName
$vmName = $QueueItem.vmName
$action = $QueueItem.action

$status = [HttpStatusCode]::OK
$body = "Request correctly processed."

switch ($action) {
    "start" { 
        try {
            Write-Information "Starting VM $vmName in resource group $rgName..."
            Start-AzVm -ResourceGroupName $rgName -Name $vmName
            Write-Information "VM started."
        }
        catch {
            Write-Error $_
            $status = [HttpStatusCode]::BadRequest
            $body = "Error while starting VM $vmName."
        }
     }
    "stop" { 
        try {
            Write-Information "Deallocating VM $vmName in resource group $rgName..."
            Stop-AzVm -ResourceGroupName $rgName -Name $vmName -Force
            Write-Information "VM deallocated."
        }
        catch {
            Write-Error $_
            $status = [HttpStatusCode]::BadRequest
            $body = "Error while deallocating VM $vmName."
        }
     }
    Default {
        $status = [HttpStatusCode]::BadRequest
        $body = "Action not valid, must be start or stop."
    }
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})

