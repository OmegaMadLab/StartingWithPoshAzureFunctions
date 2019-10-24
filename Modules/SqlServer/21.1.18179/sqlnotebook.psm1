#------------------------------------------------------------
# Copyright (c) Microsoft Corporation.  All rights reserved.
#------------------------------------------------------------

Set-StrictMode -Version Latest

function Invoke-SqlNotebook {

    [CmdletBinding(DefaultParameterSetName="ByConnectionParameters")]

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUsePSCredentialType", "Username", Justification="Intentionally allowing User/Password, in addition to a PSCredential parameter.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "Password", Justification="Intentionally allowing User/Password, in addition to a PSCredential parameter.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingUsernameAndPasswordParams", "", Justification="Intentionally allowing User/Password, in addition to a PSCredential parameter.")]

    # Parameters
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionParameters')]$ServerInstance,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionParameters')]$Database,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionParameters')][ValidateNotNullorEmpty()]$Username,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionParameters')][ValidateNotNullorEmpty()]$Password,

        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionString')][ValidateNotNullorEmpty()]$ConnectionString,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ParameterSetName = 'ByConnectionParameters')][ValidateNotNullorEmpty()][PSCredential]$Credential,
        [Parameter(Mandatory = $true, ParameterSetName='ByInputFile')]
        [Parameter(ParameterSetName = 'ByConnectionParameters')]
        [Parameter(ParameterSetName = 'ByConnectionString')]$InputFile,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName='ByInputObject')]
        [Parameter(ParameterSetName = 'ByConnectionParameters')]
        [Parameter(ParameterSetName = 'ByConnectionString')]$InputObject,
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)][ValidateNotNullorEmpty()]$OutputFile,

        [Switch]$Force
    )

    #Checks to see if OutputFile is given
    #If it is, checks to see if extension is there
    function getOutputFile($inputFile,$outputFile) {
        if($outputFile) {
            $extn = [IO.Path]::GetExtension($outputFile)
            if ($extn.Length -eq 0) {
                $outputFile = ($outputFile + ".ipynb")
            }
            $outputFile
        }
        else {
            #If User does not define Output it will use the inputFile file location
            $fileinfo = Get-Item $inputFile

            # Create an output file based on the file path of input and name
            Join-Path $fileinfo.DirectoryName ($fileinfo.BaseName + "_out" + $fileinfo.Extension)
        }
    }

    #Validates InputFile and Converts InputFile to Json Object
    function getFileContents($inputfile) {

        if (-not (Test-Path -Path $inputfile)) {
            Throw New-Object System.IO.FileNotFoundException ($inputfile + " does not exist")
        }

        $fileItem = Get-Item $inputfile

        #Checking if file is a python notebook
        if ($fileItem.Extension -ne ".ipynb") {
            Throw New-Object System.FormatException "Only ipynb files are supported"
        }

        $fileContent = Get-Content $inputfile
        try {
            $fileContentJson = ($fileContent | ConvertFrom-Json)
        }
        catch {
            Throw New-Object System.FormatException "Malformed Json file"
        }
        $fileContentJson
    }

    #Validate SQL Kernel Notebook
    function validateKernelType($fileContentJson) {
        if ($fileContentJson.metadata.kernelspec.name -ne "SQL") {
            Throw New-Object System.NotSupportedException "Kernel type '$($fileContentJson.metadata.kernelspec.name)' not supported."
        }
    }

    #Validate non-existing output file
    #If file exists and $throwifexists, an exception is thrown.
    function validateExistingOutputFile($outputfile, $throwifexists) {
        if ($outputfile -and (Test-Path $outputfile) -and $throwifexists) {
            Throw New-Object System.IO.IOException "The file '$($outputfile)' already exists. Please, specify -Force to overwrite it."
        }
    }

    #Parsing Notebook Data to Notebook Output
    function ParseTableToNotebookOutput {
        param (
            [System.Data.DataTable]
            $DataTable,

            [int]
            $CellExecutionCount
        )
        $TableHTMLText = "<table>"
        $TableSchemaFeilds = @()
        $TableHTMLText += "<tr>"
        foreach ($ColumnName in $DataTable.Columns) {
            $TableSchemaFeilds += @(@{name = $ColumnName.toString() })
            $TableHTMLText += "<th>" + $ColumnName.toString() + "</th>"
        }
        $TableHTMLText += "</tr>"
        $TableSchema = @{ }
        $TableSchema["fields"] = $TableSchemaFeilds

        $TableDataRows = @()
        foreach ($Row in $DataTable) {
            $TableDataRow = [ordered]@{ }
            $TableHTMLText += "<tr>"
            $i = 0
            foreach ($Cell in $Row.ItemArray) {
                $TableDataRow[$i.ToString()] = $Cell.toString()
                $TableHTMLText += "<td>" + $Cell.toString() + "</td>"
                $i++
            }
            $TableHTMLText += "</tr>"
            $TableDataRows += $TableDataRow
        }

        $TableDataResource = @{ }
        $TableDataResource["schema"] = $TableSchema
        $TableDataResource["data"] = $TableDataRows
        $TableData = @{ }
        $TableData["application/vnd.dataresource+json"] = $TableDataResource
        $TableData["text/html"] = $TableHTMLText
        $TableOutput = @{ }
        $TableOutput["output_type"] = "execute_result"
        $TableOutput["data"] = $TableData
        $TableOutput["metadata"] = @{ }
        $TableOutput["execution_count"] = $CellExecutionCount
        return $TableOutput
    }

    #Parsing the Error Messages to Notebook Output
    function ParseQueryErrorToNotebookOutput {
        param (
            $QueryError
        )
        <#
        Following the current syntax of errors in T-SQL notebooks from ADS
        #>
        $ErrorString = "Msg " + $QueryError.Exception.InnerException.Number +
        ", Level " + $QueryError.Exception.InnerException.Class +
        ", State " + $QueryError.Exception.InnerException.State +
        ", Line " + $QueryError.Exception.InnerException.LineNumber +
        "`r`n" + $QueryError.Exception.Message

        $ErrorOutput = @{ }
        $ErrorOutput["output_type"] = "error"
        $ErrorOutput["traceback"] = @()
        $ErrorOutput["evalue"] = $ErrorString
        return $ErrorOutput
    }

    #Parsing Messages to Notebook Output
    function ParseStringToNotebookOutput {
        param (
            [System.String]
            $InputString
        )
        <#
        Parsing the string to notebook cell output.
        It's the standard Jupyter Syntax
        #>
        $StringOutputData = @{ }
        $StringOutputData["text/html"] = $InputString
        $StringOutput = @{ }
        $StringOutput["output_type"] = "display_data"
        $StringOutput["data"] = $StringOutputData
        $StringOutput["metadata"] = @{ }
        return $StringOutput
    }

    #Start of Script
    #Checks to see if InputFile or InputObject was entered

    #Checks to InputFile Type and initializes OutputFile
    switch ($InputFile) {
        {$_ -is [System.String]} {
            $fileInformation = getFileContents($_)
            $fileContent = $fileInformation[0]
            $OutputFile = getOutputFile $_  $OutputFile
            break
        }
        {$_ -is [System.IO.FileInfo]} {
            $fileInformation = getFileContents($_.FullName)
            $fileContent = $fileInformation[0]
            $OutputFile = getOutputFile $_ $OutputFile
            break
        }
        default {
            $fileContent = $InputObject
        }
    }

    #Checks InputObject and converts that to appropriate Json object
    switch ($InputObject) {
        {$_ -is [System.String]} {
            $fileContentJson = ($InputObject | ConvertFrom-Json)
            $fileContent = $fileContentJson[0]
        }
    }

    #Validates only SQL Notebooks
    validateKernelType $fileContent

    #Validate that $OutputFile does not exist, or, if it exists a -Force was passed in.
    validateExistingOutputFile $OutputFile (-not $Force)

    #Setting params for Invoke-Sqlcmd
    $DatabaseQueryHashTable = @{ }

    #Checks to see if User entered ConnectionString or individual parameters
    if($ConnectionString) {
        $DatabaseQueryHashTable["ConnectionString"] = $ConnectionString
    }else{
        if ($ServerInstance) {
            $DatabaseQueryHashTable["ServerInstance"] = $ServerInstance
        }
        if ($Database) {
            $DatabaseQueryHashTable["Database"] = $Database
        }
        #Checks to see if User entered Credential or individual parameters
        if($Credential) {
            $DatabaseQueryHashTable["Credential"] = $Credential
        }else{
            if ($Username) {
                $DatabaseQueryHashTable["Username"] = $Username
            }
            if ($Password) {
                $DatabaseQueryHashTable["Password"] = $Password
            }
        }
    }

    #Setting additional parameters for Invoke-SQLCMD to get
    #all the information from Notebook execution to output
    $DatabaseQueryHashTable["Verbose"] = $true
    $DatabaseQueryHashTable["ErrorVariable"] = "SqlQueryError"
    $DatabaseQueryHashTable["OutputAs"] = "DataTables"

    #The first code cell number
    $cellExecutionCount = 1
    #Iterate through Notebook Cells
    $fileContent.cells | Where-Object {
        # Ignoring Markdown or raw cells
        $_.cell_type -ne "markdown" -and $_.cell_type -ne "raw" -and $_.source -ne ""
    } | ForEach-Object {
        $NotebookCellOutputs = @()

        # Getting the source T-SQL from the cell
        #$DatabaseQueryHashTable["Query"] = $_.source
        switch($_.source) {
            {($_.getType().FullName) -is [System.Object[]]} {
                $DatabaseQueryHashTable["Query"] = ($_ -join "`r`n" | Out-String)
                break
            }
            {$_.getType().FullName -is [System.String]} {
                $DatabaseQueryHashTable["Query"] = $_
                break
            }
        }

        # Executing the T-SQL Query and storing the result and the time taken to execute
        $SqlQueryExecutionTime = Measure-Command {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "SqlQueryResult", Justification="Suppressing false warning.")]
            $SqlQueryResult = @( Invoke-Sqlcmd @DatabaseQueryHashTable -ErrorAction SilentlyContinue 4>&1)
        }

        # Setting the Notebook Cell Execution Count
        # to increase count of each code cell
        $_.execution_count = $cellExecutionCount++

        $NotebookCellTableOutputs = @()

        <#
        Iterating over the results by Invoke-Sqlcmd
        There are 2 types of errors:
        1. Verbose Output: Print Statements:
            These needs to be added to the beginning of the cell outputs
        2. Datatables from the database
            These needs to be added to the end of cell outputs
        #>
        $SqlQueryResult | ForEach-Object {
            switch ($_) {
                { $_ -is [System.Management.Automation.VerboseRecord] } {
                    # Adding the print statments to the cell outputs
                    $NotebookCellOutputs += $(ParseStringToNotebookOutput($_.Message))
                    break
                }
                { $_ -is [System.Data.DataTable] } {
                    # Storing the print Tables into an array to be added later to the cell output
                    $NotebookCellTableOutputs += $(ParseTableToNotebookOutput $_  $CellExecutionCount)
                    break
                }
                { $_ -is [System.Data.DataRow] } {
                    # Storing the print row into an array to be added later to the cell output
                    $NotebookCellTableOutputs += $(ParseTableToNotebookOutput $_.Table  $CellExecutionCount)
                    break
                }
            }
        }

        if ($SqlQueryError) {
            # Adding the parsed query error from Invoke-Sqlcmd
            $NotebookCellOutputs += $(ParseQueryErrorToNotebookOutput($SqlQueryError))
        }

        if ($SqlQueryExecutionTime) {
            # Adding the parsed execution time from Measure-Command
            $NotebookCellExcutionTimeString = "Total execution time: " + $SqlQueryExecutionTime.ToString()
            $NotebookCellOutputs += $(ParseStringToNotebookOutput($NotebookCellExcutionTimeString))
        }

        # Adding the data tables
        $NotebookCellOutputs += $NotebookCellTableOutputs
        $_.outputs = $NotebookCellOutputs
    }

    # This will update the Output file according to the executed output of the notebook
    if ($OutputFile) {
        ($fileContent | ConvertTo-Json -Depth 100 ) | Out-File  -Encoding Ascii -FilePath $OutputFile
        Get-Item $OutputFile
    }
    else {
        $fileContent | ConvertTo-Json -Depth 100
    }
}

# SIG # Begin signature block
# MIIjtgYJKoZIhvcNAQcCoIIjpzCCI6MCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAzhZRgT7TnSBlE
# KiFo1Vu4BpGvqrzgm8I9cW5+An64IKCCDYUwggYDMIID66ADAgECAhMzAAABUptA
# n1BWmXWIAAAAAAFSMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMTkwNTAyMjEzNzQ2WhcNMjAwNTAyMjEzNzQ2WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQCxp4nT9qfu9O10iJyewYXHlN+WEh79Noor9nhM6enUNbCbhX9vS+8c/3eIVazS
# YnVBTqLzW7xWN1bCcItDbsEzKEE2BswSun7J9xCaLwcGHKFr+qWUlz7hh9RcmjYS
# kOGNybOfrgj3sm0DStoK8ljwEyUVeRfMHx9E/7Ca/OEq2cXBT3L0fVnlEkfal310
# EFCLDo2BrE35NGRjG+/nnZiqKqEh5lWNk33JV8/I0fIcUKrLEmUGrv0CgC7w2cjm
# bBhBIJ+0KzSnSWingXol/3iUdBBy4QQNH767kYGunJeY08RjHMIgjJCdAoEM+2mX
# v1phaV7j+M3dNzZ/cdsz3oDfAgMBAAGjggGCMIIBfjAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQU3f8Aw1sW72WcJ2bo/QSYGzVrRYcw
# VAYDVR0RBE0wS6RJMEcxLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEWMBQGA1UEBRMNMjMwMDEyKzQ1NDEzNjAfBgNVHSMEGDAW
# gBRIbmTlUAXTgqoXNzcitW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIw
# MTEtMDctMDguY3JsMGEGCCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDEx
# XzIwMTEtMDctMDguY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIB
# AJTwROaHvogXgixWjyjvLfiRgqI2QK8GoG23eqAgNjX7V/WdUWBbs0aIC3k49cd0
# zdq+JJImixcX6UOTpz2LZPFSh23l0/Mo35wG7JXUxgO0U+5drbQht5xoMl1n7/TQ
# 4iKcmAYSAPxTq5lFnoV2+fAeljVA7O43szjs7LR09D0wFHwzZco/iE8Hlakl23ZT
# 7FnB5AfU2hwfv87y3q3a5qFiugSykILpK0/vqnlEVB0KAdQVzYULQ/U4eFEjnis3
# Js9UrAvtIhIs26445Rj3UP6U4GgOjgQonlRA+mDlsh78wFSGbASIvK+fkONUhvj8
# B8ZHNn4TFfnct+a0ZueY4f6aRPxr8beNSUKn7QW/FQmn422bE7KfnqWncsH7vbNh
# G929prVHPsaa7J22i9wyHj7m0oATXJ+YjfyoEAtd5/NyIYaE4Uu0j1EhuYUo5VaJ
# JnMaTER0qX8+/YZRWrFN/heps41XNVjiAawpbAa0fUa3R9RNBjPiBnM0gvNPorM4
# dsV2VJ8GluIQOrJlOvuCrOYDGirGnadOmQ21wPBoGFCWpK56PxzliKsy5NNmAXcE
# x7Qb9vUjY1WlYtrdwOXTpxN4slzIht69BaZlLIjLVWwqIfuNrhHKNDM9K+v7vgrI
# bf7l5/665g0gjQCDCN6Q5sxuttTAEKtJeS/pkpI+DbZ/MIIHejCCBWKgAwIBAgIK
# YQ6Q0gAAAAAAAzANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlm
# aWNhdGUgQXV0aG9yaXR5IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEw
# OTA5WjB+MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYD
# VQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+la
# UKq4BjgaBEm6f8MMHt03a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc
# 6Whe0t+bU7IKLMOv2akrrnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4D
# dato88tt8zpcoRb0RrrgOGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+
# lD3v++MrWhAfTVYoonpy4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nk
# kDstrjNYxbc+/jLTswM9sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6
# A4aN91/w0FK/jJSHvMAhdCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmd
# X4jiJV3TIUs+UsS1Vz8kA/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL
# 5zmhD+kjSbwYuER8ReTBw3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zd
# sGbiwZeBe+3W7UvnSSmnEyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3
# T8HhhUSJxAlMxdSlQy90lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS
# 4NaIjAsCAwEAAaOCAe0wggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRI
# bmTlUAXTgqoXNzcitW2oynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAL
# BgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBD
# uRQFTuHqp8cx0SOJNDBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3JsMF4GCCsGAQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3J0MIGfBgNVHSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1h
# cnljcHMuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkA
# YwB5AF8AcwB0AGEAdABlAG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn
# 8oalmOBUeRou09h0ZyKbC5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7
# v0epo/Np22O/IjWll11lhJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0b
# pdS1HXeUOeLpZMlEPXh6I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/
# KmtYSWMfCWluWpiW5IP0wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvy
# CInWH8MyGOLwxS3OW560STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBp
# mLJZiWhub6e3dMNABQamASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJi
# hsMdYzaXht/a8/jyFqGaJ+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYb
# BL7fQccOKO7eZS/sl/ahXJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbS
# oqKfenoi+kiVH6v7RyOA9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sL
# gOppO6/8MO0ETI7f33VtY5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtX
# cVZOSEXAQsmbdlsKgEhr/Xmfwb1tbWrJUnMTDXpQzTGCFYcwghWDAgEBMIGVMH4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01p
# Y3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTECEzMAAAFSm0CfUFaZdYgAAAAA
# AVIwDQYJYIZIAWUDBAIBBQCggdowGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGmk
# VJPWhUA4KDcuz/4YAXMl9UuFA3JDDBxIqytQRKLdMG4GCisGAQQBgjcCAQwxYDBe
# oDqAOABTAFEATAAgAFMAZQByAHYAZQByACAATQBhAG4AYQBnAGUAbQBlAG4AdAAg
# AFMAdAB1AGQAaQBvoSCAHmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9zcWwvIDAN
# BgkqhkiG9w0BAQEFAASCAQBt5LHoUhaQtq/humc8nt8mGHG7/f6EWS6KU3t3Ay1D
# LGyHDfc1uu3bJwxHyPF5ijmLi8Xic/PAT47ebxq9aiO0kHIGSgUQh73J/0c9yTWW
# C2NDwQNK1aSxdw5N0tw6alJwEGRTjx/pVKbiVk3yIVzRxVPpRVTMRoxrLgKKCeEm
# kttss2CEQNfhlBaQr6ojVU3v8e1bigcse3CW0mm4++FSYXA+Wxw88Wsdkdv9UHHJ
# H4TSMxUyXu0hDCcNLlJvHM8tk0PKBU7DgIPLf1MNC41eUdyanr1wiIdh/YibNlT9
# BxCpSfrbjTOUfN40USh9a/svXXuxsLoERj6HdL2CZ3IsoYIS5TCCEuEGCisGAQQB
# gjcDAwExghLRMIISzQYJKoZIhvcNAQcCoIISvjCCEroCAQMxDzANBglghkgBZQME
# AgEFADCCAVEGCyqGSIb3DQEJEAEEoIIBQASCATwwggE4AgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIOV2fltYYY+n6XUGm7nA7xA0oJjAPmN85Xbgm8S4
# PLdwAgZdXvMIWOwYEzIwMTkwOTIwMjAzMzE2Ljc0OVowBIACAfSggdCkgc0wgcox
# CzAJBgNVBAYTAlVTMQswCQYDVQQIEwJXQTEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOkQwODItNEJGRC1FRUJBMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBzZXJ2aWNloIIOPDCCBPEwggPZoAMCAQICEzMAAADiGDh7ZunqwdgAAAAAAOIw
# DQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcN
# MTgwODIzMjAyNzAzWhcNMTkxMTIzMjAyNzAzWjCByjELMAkGA1UEBhMCVVMxCzAJ
# BgNVBAgTAldBMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlv
# bnMgTGltaXRlZDEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046RDA4Mi00QkZELUVF
# QkExJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIHNlcnZpY2UwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCoqwO9hRdzQi1uZnyzvw9BGeWHLNNK
# IjEorLFywelhfRjXT+/EMxcAMqcVv/qmUnM6mh2wx/IZW8ZM39w4mIAHaUI5xpC7
# o8CrVkmj9vf5VX+4xah8vb+nh/i3TotC77az0Vt+DMgr6cWcjluB9Ydz5MQgS+UW
# ttbA6oHFS9ZntKLMPEE1EV5iOC8ni3Ux9wnCNgIDQ1047BQX90LDviWMgDmFq03C
# 58sFTeg64oJoKwyZOcPsEeFax35dk/T0WW2flA7dd8MMgfXeiFEbs1fJR7AFXxfL
# fUtGhlT5pEN3NsGjoR6bKelRDPk+Q9j4fMSV9a/Ns+u1kZZhnDj9jVgtAgMBAAGj
# ggEbMIIBFzAdBgNVHQ4EFgQUiT6Q+gbD9qfnKwyS9t9r6BLS8XswHwYDVR0jBBgw
# FoAU1WM6XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDov
# L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENB
# XzIwMTAtMDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAx
# MC0wNy0wMS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDAN
# BgkqhkiG9w0BAQsFAAOCAQEAEUB7uyEngbiUhyrg0SNOO9OHB9AewWM3hCKw9eWs
# L4jEXGCHyDh6bxs2TlkID9h5tEa+5L01LtVa0kmkO4tYD1nYajJsOVgZ0kuW8XjI
# YcfVLAEnhPOL1LvNjXmWqRkox9/GAG+Fk/k7Yk5HKCOfawPgkwqtdPLbSMVX2XK9
# 4ne+jhEyB9B74ZZ8Tjlo8BsuLpemWuUaEyxv6KNq6xplYtxcKzVhns2CwTg7hLI8
# xt+pQkbQSgtmQB32zs+cLZFB26oe/ZlCqHIz+K96sX+UzfO8n+oNbk8fifKXZwIu
# Yh7fmbWp4Fqp1UxPD6CERFoQVZRhX0HZBC1Mdjq/dGgKljCCBnEwggRZoAMCAQIC
# CmEJgSoAAAAAAAIwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRp
# ZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTEwMDcwMTIxMzY1NVoXDTI1MDcwMTIx
# NDY1NVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQCpHQ28dxGKOiDs/BOX9fp/aZRrdFQQ1aUKAIKF
# ++18aEssX8XD5WHCdrc+Zitb8BVTJwQxH0EbGpUdzgkTjnxhMFmxMEQP8WCIhFRD
# DNdNuDgIs0Ldk6zWczBXJoKjRQ3Q6vVHgc2/JGAyWGBG8lhHhjKEHnRhZ5FfgVSx
# z5NMksHEpl3RYRNuKMYa+YaAu99h/EbBJx0kZxJyGiGKr0tkiVBisV39dx898Fd1
# rL2KQk1AUdEPnAY+Z3/1ZsADlkR+79BL/W7lmsqxqPJ6Kgox8NpOBpG2iAg16Hgc
# sOmZzTznL0S6p/TcZL2kAcEgCZN4zfy8wMlEXV4WnAEFTyJNAgMBAAGjggHmMIIB
# 4jAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU1WM6XIoxkPNDe3xGG8UzaFqF
# bVUwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1Ud
# EwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYD
# VR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwv
# cHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEB
# BE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9j
# ZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwgaAGA1UdIAEB/wSBlTCB
# kjCBjwYJKwYBBAGCNy4DMIGBMD0GCCsGAQUFBwIBFjFodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vUEtJL2RvY3MvQ1BTL2RlZmF1bHQuaHRtMEAGCCsGAQUFBwICMDQe
# MiAdAEwAZQBnAGEAbABfAFAAbwBsAGkAYwB5AF8AUwB0AGEAdABlAG0AZQBuAHQA
# LiAdMA0GCSqGSIb3DQEBCwUAA4ICAQAH5ohRDeLG4Jg/gXEDPZ2joSFvs+umzPUx
# vs8F4qn++ldtGTCzwsVmyWrf9efweL3HqJ4l4/m87WtUVwgrUYJEEvu5U4zM9GAS
# inbMQEBBm9xcF/9c+V4XNZgkVkt070IQyK+/f8Z/8jd9Wj8c8pl5SpFSAK84Dxf1
# L3mBZdmptWvkx872ynoAb0swRCQiPM/tA6WWj1kpvLb9BOFwnzJKJ/1Vry/+tuWO
# M7tiX5rbV0Dp8c6ZZpCM/2pif93FSguRJuI57BlKcWOdeyFtw5yjojz6f32WapB4
# pm3S4Zz5Hfw42JT0xqUKloakvZ4argRCg7i1gJsiOCC1JeVk7Pf0v35jWSUPei45
# V3aicaoGig+JFrphpxHLmtgOR5qAxdDNp9DvfYPw4TtxCd9ddJgiCGHasFAeb73x
# 4QDf5zEHpJM692VHeOj4qEir995yfmFrb3epgcunCaw5u+zGy9iCtHLNHfS4hQEe
# gPsbiSpUObJb2sgNVZl6h3M7COaYLeqN4DMuEin1wC9UJyH3yKxO2ii4sanblrKn
# QqLJzxlBTeCG+SqaoxFmMNO7dDJL32N79ZmKLxvHIa9Zta7cRDyXUHHXodLFVeNp
# 3lfB0d4wwP3M5k37Db9dT+mdHhk4L7zPWAUu7w2gUDXa7wknHNWzfjUeCLraNtvT
# X4/edIhJEqGCAs4wggI3AgEBMIH4oYHQpIHNMIHKMQswCQYDVQQGEwJVUzELMAkG
# A1UECBMCV0ExEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEtMCsGA1UECxMkTWljcm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9u
# cyBMaW1pdGVkMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpEMDgyLTRCRkQtRUVC
# QTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgc2VydmljZaIjCgEBMAcG
# BSsOAwIaAxUAckAlIXhDnr2iPWXP90Bq5F+NoguggYMwgYCkfjB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIFAOEvrIowIhgPMjAx
# OTA5MjEwMzUyNDJaGA8yMDE5MDkyMjAzNTI0MlowdzA9BgorBgEEAYRZCgQBMS8w
# LTAKAgUA4S+sigIBADAKAgEAAgIJIwIB/zAHAgEAAgIRbjAKAgUA4TD+CgIBADA2
# BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIB
# AAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAIA4PU9QkNU95WRHOsftHxrAlRSwUM5Q
# H33IgFNdIzH+LfYcg2QI1XmbgUWqzrIt8GoX/uN5eQG6HMrfmWUe1Kzo+SZyRKHb
# /DSgIgvbdIKthP1PCDcU0+pXV/gDk2Ckdmo2ixaZbmxRNJfdVoCriSdPkG5KQ+TT
# xU3FLAFdDD5FMYIDDTCCAwkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAADiGDh7ZunqwdgAAAAAAOIwDQYJYIZIAWUDBAIBBQCgggFKMBoG
# CSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgyEPigVrt
# 6UlLVkCmN2t2bUmc9USpFF8J1SpRzkujLCYwgfoGCyqGSIb3DQEJEAIvMYHqMIHn
# MIHkMIG9BCDfAaSUpkAhrm1sFWuLVvmjL3qBzF/5w51TfH4gzjLKyzCBmDCBgKR+
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAA4hg4e2bp6sHYAAAA
# AADiMCIEIJ3Zd7YkfacqBAhTne/AiI3gqiJluKQtfZA67UyNag9MMA0GCSqGSIb3
# DQEBCwUABIIBAGnBgkBmRGUhaaNs9CZ6qaGQVvEX0bYsO6gizTUedyz/ddsmkzOT
# oB4KhH6tnuAOfRkufw96P6AMoLAXjsO1J/XELAHyhIaQcJo38Z3cgSL99Qvaxuiw
# hQ0T/7CthSvuBPwADheWP93Y5ae5QE7Feiyo3lusMXetG3qu/36Mw7FfkagSa61L
# F6E7N3vh31w30eBkwPOoN1HGOvMDAinQCM26hGm83ZY8KLs8bF8TR/b9uu9Ajrkt
# QD2ZR2zGleyknohRw0qqCGXponq+AsRsccRs3dbMiyquPFTwUsJkfGPUr9TF2QPs
# 5G1AfH3wNF9V9vuazvgOgpL96dBQjuev0JI=
# SIG # End signature block
