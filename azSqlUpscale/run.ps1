using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Function Get-NextCapacity {

    param (
        [string]$Location,
        [string]$GreaterThanSvcObj 
    )

    $currentSvcObj = Get-AzSqlServerServiceObjective -location $Location `
                        -ServiceObjectiveName $GreaterThanSvcObj

    Write-Verbose "Current Service Objective: $($currentSvcObj.ServiceObjectiveName)"

    $nextCapacity = Get-AzSqlServerServiceObjective -location $Location | 
                        Where-Object {$_.Edition -eq $currentSvcObj.Edition -and $_.Capacity -gt $currentSvcObj.Capacity } |
                        Sort-Object -property Capacity |
                        Select -first 1

    if(!$nextCapacity) {
        switch ($currentSvcObj.Edition) {
            "Basic"     { $nextEdition = "Standard" }
            "Standard"  { $nextEdition = "Premium" }
            default     { 
                            Write-Verbose "Higher capacity not available. Try to scale up manually."
                            Return $null
                        } 
        }

        Write-Verbose "Higher capacity not found. Switching to $nextEdition tier."

        $nextCapacity = Get-AzSqlServerServiceObjective -location $Location | 
                            Where-Object {$_.Edition -eq $nextEdition -and $_.Capacity -gt $currentSvcObj.Capacity } |
                            Sort-Object -property Capacity |
                            Select -first 1
    }

    Write-Verbose "New Service Objective: $nextCapacity"
    $nextCapacity
}

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Get Alert payload
$alert = $Request.Body

if (-not $alert) {
    $status = [HttpStatusCode]::BadRequest
    $body = "This function expects to be invoked by an Azure Monitor Alert"
} else {
    $azSqlDb = $alert.body.data.alertContext.AffectedConfigurationItems

    $azSqlDb | % { 
        Write-Host "Looking for database $($_)..."
        $resourceIdArray = $_.split("/")
        $server = Get-AzSqlServer -ResourceGroupName $resourceIdArray[4] -ServerName $resourceIdArray[8]
        $db = $server | Get-AzSqlDatabase -DatabaseName $resourceIdArray[10]

        Write-Host "Found database $($db.ResourceId)"

        if ($db.CurrentServiceObjectiveName -eq $db.RequestedServiceObjectiveName) {

            $nextCapacityAvailable = Get-NextCapacity -Location $server.location `
                                        -GreaterThanSvcObj $db.CurrentServiceObjectiveName 
        
            if ($nextCapacityAvailable) {
                $newRequestedServiceObjective = $nextCapacityAvailable.ServiceObjectiveName
                $db | Set-AzSqlDatabase -RequestedServiceObjectiveName $newRequestedServiceObjective
            }
            else {
                Write-Host "Max capacity reached, or for current Edition you have to scale up database manually."
            }
        }
        else {
            Write-Host "Database is currently transitioning from $($db.CurrentServiceObjectiveName) to $($db.RequestedServiceObjectiveName). No actions will be executed by this runbook at this time."
        }
    }

    $status = [HttpStatusCode]::OK
    $body = "OK"
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})