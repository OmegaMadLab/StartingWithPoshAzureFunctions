param($eventGridEvent, $TriggerMetadata)

$vmId = $eventGridEvent.data.resourceUri

try {
    Write-Information "Looking for VM $vmId..."
    $vm = Get-AzResource -ResourceId $vmId
    Write-Information "VM $($vm.Name) found."
    if($vm.Tags["maintenance"] -ne "true") {
        Write-Information "VM is not marked for maintenance. Trying to restart it..."
        $vm | Start-AzVm
        Write-Information "VM started."
    } else {
        Write-Information "VM is marked for maintenance. Leaving it alone."
    }
}
catch {
    Write-Error $_
}
