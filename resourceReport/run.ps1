# Input bindings are passed in via param block.
param($Timer)

# KQL query to retrieve unattached managed disks
$kqlQry = "Resources | where type == 'microsoft.compute/disks' and isempty(managedBy) == true | project subscriptionId, resourceGroup, name, Sku = sku.name, ['Size GB'] = properties.diskSizeGB"

$qryResult = Search-AzGraph -Query $kqlQry

$html = $qryResult | ConvertTo-Html -Fragment -PreContent "<h1>Disk not attached to VMs</h1>" -PostContent "<h6>Executed by Azure Function</h6>"

$mail = @{
    "personalizations" = @(
        @{
            "to" = @(
                @{
                    "email" = $env:ToMailAddress 
                }
            )
        }
    )
    "from" = @{ 
        "email" = "AzFunctionDemo@omegamadlab.test" 
    }        
    "subject" = "Unattached disk report"
    "content" = @(
        @{
            "type" = "text/html"
            "value" = [system.string]::Join(" ", $html)
        }
    )
}

Push-OutputBinding -Name message -Value (ConvertTo-Json -InputObject $mail -Depth 4)  

Write-Information "Report sent."
