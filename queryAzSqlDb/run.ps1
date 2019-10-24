using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Information "PowerShell HTTP trigger function processed a request."

# query SQL using secrets from KeyVault (referenced in appSettings)
try {
    Write-Information "Query Azure SQL Database..."
    $qryOut = Invoke-SqlCmd -ServerInstance $env:SqlServer `
                    -Username $env:SqlAdmin `
                    -Password $env:SqlAdminPwd `
                    -Database "DemoDB" `
                    -Query "SELECT TOP 10 CustomerID, CompanyName, Phone FROM SalesLT.Customer"
    Write-Information "Query executed."
    $status = [HttpStatusCode]::OK
    $body = $qryOut | ConvertTo-Html -PreContent "SELECT TOP 10 CustomerID, CompanyName, Phone FROM SalesLT.Customer - results"
}
catch {
    Write-Error $_
    $status = [HttpStatusCode]::BadRequest
    $body = "Error while processing query."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    headers = @{'content-type' = 'text/html'}
    StatusCode = $status
    Body = [system.string]::Join(" ", $body)
})
