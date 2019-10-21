using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Get mail address and validate it
$emailAddress = $Request.Query.email
if (-not $emailAddress) {
    $emailAddress = $Request.Body.email
}

$emailRegex = "^([\w-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([\w-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$"

if ($emailAddress -and $emailAddress -match $emailRegex) {

    Write-Information "$emailAddress appears to be a valid email address. Trying to send message..."
    
    try {
        $mail = @{
            "personalizations" = @(
                @{
                    "to" = @(
                        @{
                            "email" = $emailAddress 
                        }
                    )
                }
            )
            "from" = @{ 
                "email" = "AzFunctionDemo@omegamadlab.test" 
            }        
            "subject" = "Mail test"
            "content" = @(
                @{
                    "type" = "text/plain"
                    "value" = "input"
                }
            )
        }
        
        Push-OutputBinding -Name message -Value (ConvertTo-Json -InputObject $mail -Depth 4)  

        $status = [HttpStatusCode]::OK
        $body = "Mail sent to $emailAddress"

        Write-Information "Mail sent."
    }
    catch {
        Write-Error $_
        $status = [HttpStatusCode]::BadRequest
        $body = "Error while sending email."
    }
}
else {
    $status = [HttpStatusCode]::BadRequest
    $body = "Please pass a valid email address on the query string or in the request body."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $status
    Body = $body
})
