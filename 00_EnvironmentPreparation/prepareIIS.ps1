Install-WindowsFeature -name web-server
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Output "Hello from Demo-WINVM" | Out-File C:\inetpub\wwwroot\default.htm -Force