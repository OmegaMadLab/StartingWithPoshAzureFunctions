using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$ip = $Request.Query.ip
if (-not $ip) {
    $ip = $Request.Body.ip
}

if ($ip) {
    $status = [HttpStatusCode]::OK
    
    $testOut = Invoke-RestMethod -Uri "http://$ip" -Method Get -ContentType "text/html"
    
    $body = $testOut
}
else {
    $status = [HttpStatusCode]::BadRequest
    $body = "Please pass a computer name on the query string or in the request body."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    ContentType = "text/html" 
    Body = $body
})
