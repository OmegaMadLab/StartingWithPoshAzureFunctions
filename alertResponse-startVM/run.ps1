using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Get Alert payload
$alert = $Request.Body

if (-not $alert) {
    $status = [HttpStatusCode]::BadRequest
    $body = "This function expects to be invoked by an Azure Monitor Alert"
} else {
    $computers = $alert.body.data.alertContext.AffectedConfigurationItems

    $computers | % { 
        Write-Host "Looking for $($_)..."
        $shortName = $_.split(".")[0]
        $vm = Get-AzVm | ? { $_.OsProfile.ComputerName -eq $shortName }

        Write-Host "Found VM $($vm.id)"

        if (($vm | Get-AzVm -Status).Statuses.Code[1] -ne 'PowerState/running') {
            $tagValue = $vm.Tags["maintenance"]
            if($tagValue -ne "true")
            {
                Write-host "VM is not tagged as in maintenance. Restarting it."
                $vm | Start-AzVm
            } else {
                Write-host "VM is in maintenance mode. Ignoring it."
            }
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
