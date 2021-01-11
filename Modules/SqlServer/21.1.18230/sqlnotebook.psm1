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
# MIIjvgYJKoZIhvcNAQcCoIIjrzCCI6sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAzhZRgT7TnSBlE
# KiFo1Vu4BpGvqrzgm8I9cW5+An64IKCCDYEwggX/MIID56ADAgECAhMzAAABh3IX
# chVZQMcJAAAAAAGHMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAwMzA0MTgzOTQ3WhcNMjEwMzAzMTgzOTQ3WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDOt8kLc7P3T7MKIhouYHewMFmnq8Ayu7FOhZCQabVwBp2VS4WyB2Qe4TQBT8aB
# znANDEPjHKNdPT8Xz5cNali6XHefS8i/WXtF0vSsP8NEv6mBHuA2p1fw2wB/F0dH
# sJ3GfZ5c0sPJjklsiYqPw59xJ54kM91IOgiO2OUzjNAljPibjCWfH7UzQ1TPHc4d
# weils8GEIrbBRb7IWwiObL12jWT4Yh71NQgvJ9Fn6+UhD9x2uk3dLj84vwt1NuFQ
# itKJxIV0fVsRNR3abQVOLqpDugbr0SzNL6o8xzOHL5OXiGGwg6ekiXA1/2XXY7yV
# Fc39tledDtZjSjNbex1zzwSXAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUhov4ZyO96axkJdMjpzu2zVXOJcsw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDU4Mzg1MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAixmy
# S6E6vprWD9KFNIB9G5zyMuIjZAOuUJ1EK/Vlg6Fb3ZHXjjUwATKIcXbFuFC6Wr4K
# NrU4DY/sBVqmab5AC/je3bpUpjtxpEyqUqtPc30wEg/rO9vmKmqKoLPT37svc2NV
# BmGNl+85qO4fV/w7Cx7J0Bbqk19KcRNdjt6eKoTnTPHBHlVHQIHZpMxacbFOAkJr
# qAVkYZdz7ikNXTxV+GRb36tC4ByMNxE2DF7vFdvaiZP0CVZ5ByJ2gAhXMdK9+usx
# zVk913qKde1OAuWdv+rndqkAIm8fUlRnr4saSCg7cIbUwCCf116wUJ7EuJDg0vHe
# yhnCeHnBbyH3RZkHEi2ofmfgnFISJZDdMAeVZGVOh20Jp50XBzqokpPzeZ6zc1/g
# yILNyiVgE+RPkjnUQshd1f1PMgn3tns2Cz7bJiVUaqEO3n9qRFgy5JuLae6UweGf
# AeOo3dgLZxikKzYs3hDMaEtJq8IP71cX7QXe6lnMmXU/Hdfz2p897Zd+kU+vZvKI
# 3cwLfuVQgK2RZ2z+Kc3K3dRPz2rXycK5XCuRZmvGab/WbrZiC7wJQapgBodltMI5
# GMdFrBg9IeF7/rP4EqVQXeKtevTlZXjpuNhhjuR+2DMt/dWufjXpiW91bo3aH6Ea
# jOALXmoxgltCp1K7hrS6gmsvj94cLRf50QQ4U8Qwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVkzCCFY8CAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAYdyF3IVWUDHCQAAAAABhzAN
# BglghkgBZQMEAgEFAKCB2jAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgaaRUk9aF
# QDgoNy7P/hgBcyX1S4UDckMMHEirK1BEot0wbgYKKwYBBAGCNwIBDDFgMF6gOoA4
# AFMAUQBMACAAUwBlAHIAdgBlAHIAIABNAGEAbgBhAGcAZQBtAGUAbgB0ACAAUwB0
# AHUAZABpAG+hIIAeaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3NxbC8gMA0GCSqG
# SIb3DQEBAQUABIIBAG6HrpH792mmQmB7kVhRl2eetQFLwqsUespIe712bKYr0l6l
# 5ajCZP4zq0tEACjWJsTh6Xlh+syxuiwMLyhRMOPzaWrusTyBkSrojXu/u2q7Me33
# 6q6IKUhWRudlk3sAtONtZcdjUff+/GvS0LVyteODBkO6TkdLNWNvN48u52/nwZj8
# CRt/bfvslVr14/hi2i0LgnN0gejHkkRdc5TC88AvRjHg91nyoaKfUEDLnU1Aytzs
# po5M7boDdKecOHSlqaWXcpvWLqr5W0DTa5jPafAwPvT+MS2DnymRJVP2TYzd50ut
# 9uysp1TxM1KIj2+oFYtCIY1jkl/TGr2pRuAB14WhghLxMIIS7QYKKwYBBAGCNwMD
# ATGCEt0wghLZBgkqhkiG9w0BBwKgghLKMIISxgIBAzEPMA0GCWCGSAFlAwQCAQUA
# MIIBVQYLKoZIhvcNAQkQAQSgggFEBIIBQDCCATwCAQEGCisGAQQBhFkKAwEwMTAN
# BglghkgBZQMEAgEFAAQgbVgQZiEVJZptQDHnMjpLJa1RxhHffpISnLPaktQEAX4C
# Bl+7yU4zHRgTMjAyMDExMjYwOTU0MTMuNzY1WjAEgAIB9KCB1KSB0TCBzjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEpMCcGA1UECxMgTWljcm9z
# b2Z0IE9wZXJhdGlvbnMgUHVlcnRvIFJpY28xJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOjQ2MkYtRTMxOS0zRjIwMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNloIIORDCCBPUwggPdoAMCAQICEzMAAAEky80CoRdwXJoAAAAAASQw
# DQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcN
# MTkxMjE5MDExNDU3WhcNMjEwMzE3MDExNDU3WjCBzjELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEpMCcGA1UECxMgTWljcm9zb2Z0IE9wZXJhdGlv
# bnMgUHVlcnRvIFJpY28xJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjQ2MkYtRTMx
# OS0zRjIwMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIB
# IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkJsqOA2eGO8yWdE0C3Htfc3l
# lmRJ9QVQvJaxUnWmfIyxIhOKaDWrc5DUiR/T/eCDxQblMhGbvAfyyMG2gHee7MXP
# XUJ6AgVxqdie3TnQm+etRMp4A9RHmkulN4/dASAv4JY5ziVOD9fGOdC/TUUPtNOf
# 0MS47eSnQZDzsyN3myzErQrWrghY0UDJGnHmfxWbdWbWKJUvkUwNQqyXkb9KpB2I
# QOfxyphupYxXNYf3g90p3DWYgdOgFEI2xH0EcdbM2RJL5HRZGKkFJKispPty4uUQ
# FiEOjwBje4waW/SQtEscBJn6zPad+SlbYJW35seFWYzr/mqK7Z/t5ihNgm5wUQID
# AQABo4IBGzCCARcwHQYDVR0OBBYEFLsd0XKsYoiEPG/KksDWUP/AZFKwMB8GA1Ud
# IwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRPME0wS6BJoEeGRWh0
# dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1RpbVN0
# YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKG
# Pmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljVGltU3RhUENB
# XzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUH
# AwgwDQYJKoZIhvcNAQELBQADggEBAGjdDM241GDN1+XADhTt/d7YJwaXB2DqKLj3
# xwGJKtOlYo7eqrPmm+AcCTiGHrL8UtjzRHn2KcvBxW7IPbhLckR1KJ7jLW0Lkmm3
# B5HWqXFEkJEzi8buc+0gLh4AwpxeCi+7SZMW/vGkUBWlG6+56lH3WAh17fbyW/Ud
# NMkJX8sEGTzdeLucIY8Xn0XF4itwTfbG3hgmASkQCKR4yq9YJMzI+qWa/H0n3Z/F
# TdxBzDaPYRbCo4PlPc3PYdZ89XzSyKEPUDpjkeGOlL21oM+zsIjnwjbXUXfKx6A3
# I56wbcxOtIkfI8wspgUPFwbWd5XSWKS2/5Nb3buxQ5VzNxJSFAswggZxMIIEWaAD
# AgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBD
# ZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDEyMTM2NTVaFw0yNTA3
# MDEyMTQ2NTVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIIBIjANBgkq
# hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqR0NvHcRijog7PwTl/X6f2mUa3RUENWl
# CgCChfvtfGhLLF/Fw+Vhwna3PmYrW/AVUycEMR9BGxqVHc4JE458YTBZsTBED/Fg
# iIRUQwzXTbg4CLNC3ZOs1nMwVyaCo0UN0Or1R4HNvyRgMlhgRvJYR4YyhB50YWeR
# X4FUsc+TTJLBxKZd0WETbijGGvmGgLvfYfxGwScdJGcSchohiq9LZIlQYrFd/Xcf
# PfBXday9ikJNQFHRD5wGPmd/9WbAA5ZEfu/QS/1u5ZrKsajyeioKMfDaTgaRtogI
# Neh4HLDpmc085y9Euqf03GS9pAHBIAmTeM38vMDJRF1eFpwBBU8iTQIDAQABo4IB
# 5jCCAeIwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNVjOlyKMZDzQ3t8RhvF
# M2hahW1VMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAP
# BgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjE
# MFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kv
# Y3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEF
# BQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MIGgBgNVHSABAf8E
# gZUwgZIwgY8GCSsGAQQBgjcuAzCBgTA9BggrBgEFBQcCARYxaHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL1BLSS9kb2NzL0NQUy9kZWZhdWx0Lmh0bTBABggrBgEFBQcC
# AjA0HjIgHQBMAGUAZwBhAGwAXwBQAG8AbABpAGMAeQBfAFMAdABhAHQAZQBtAGUA
# bgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAB+aIUQ3ixuCYP4FxAz2do6Ehb7Pr
# psz1Mb7PBeKp/vpXbRkws8LFZslq3/Xn8Hi9x6ieJeP5vO1rVFcIK1GCRBL7uVOM
# zPRgEop2zEBAQZvcXBf/XPleFzWYJFZLdO9CEMivv3/Gf/I3fVo/HPKZeUqRUgCv
# OA8X9S95gWXZqbVr5MfO9sp6AG9LMEQkIjzP7QOllo9ZKby2/QThcJ8ySif9Va8v
# /rbljjO7Yl+a21dA6fHOmWaQjP9qYn/dxUoLkSbiOewZSnFjnXshbcOco6I8+n99
# lmqQeKZt0uGc+R38ONiU9MalCpaGpL2eGq4EQoO4tYCbIjggtSXlZOz39L9+Y1kl
# D3ouOVd2onGqBooPiRa6YacRy5rYDkeagMXQzafQ732D8OE7cQnfXXSYIghh2rBQ
# Hm+98eEA3+cxB6STOvdlR3jo+KhIq/fecn5ha293qYHLpwmsObvsxsvYgrRyzR30
# uIUBHoD7G4kqVDmyW9rIDVWZeodzOwjmmC3qjeAzLhIp9cAvVCch98isTtoouLGp
# 25ayp0Kiyc8ZQU3ghvkqmqMRZjDTu3QyS99je/WZii8bxyGvWbWu3EQ8l1Bx16HS
# xVXjad5XwdHeMMD9zOZN+w2/XU/pnR4ZOC+8z1gFLu8NoFA12u8JJxzVs341Hgi6
# 2jbb01+P3nSISRKhggLSMIICOwIBATCB/KGB1KSB0TCBzjELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEpMCcGA1UECxMgTWljcm9zb2Z0IE9wZXJh
# dGlvbnMgUHVlcnRvIFJpY28xJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjQ2MkYt
# RTMxOS0zRjIwMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNl
# oiMKAQEwBwYFKw4DAhoDFQCXA+U0Kr5SfnhR/Et7/ApLVdzieqCBgzCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3DQEBBQUAAgUA42mT
# SDAiGA8yMDIwMTEyNjA2MzY1NloYDzIwMjAxMTI3MDYzNjU2WjB3MD0GCisGAQQB
# hFkKBAExLzAtMAoCBQDjaZNIAgEAMAoCAQACAhm5AgH/MAcCAQACAhFYMAoCBQDj
# auTIAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMH
# oSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQEFBQADgYEAJWHLoxkPo/oZSrz0FLCu
# Nh0qN/QsIZ086i/rVEc4fQyW9MdOoP/HrCCCM0RUL42UBCfmmr/8NOADPI/lfdAv
# nnHb79OZPv7g+Wdau4MYEJn1W8Y28zZu6UAIE/oBM4HJQVnikWLIVNajcmCsRfdU
# kaHIRIMxRsKdf7+lRPDj8xkxggMNMIIDCQIBATCBkzB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMAITMwAAASTLzQKhF3BcmgAAAAABJDANBglghkgBZQMEAgEF
# AKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEi
# BCCTrgB+C776z8XLZ4mBPxME9X2c+55AylhxCiqrdmuFDTCB+gYLKoZIhvcNAQkQ
# Ai8xgeowgecwgeQwgb0EIGI44eiiGov5ftdr/bmOnXBOtDFiVgYuzOKz+cBOKuMg
# MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAEky80C
# oRdwXJoAAAAAASQwIgQgYzI5vZM5XAEwMrRyXjhz7u9wAMvO7Ui+tDwi1njXhBkw
# DQYJKoZIhvcNAQELBQAEggEAZh7zDkc+Vzsqk9J/lcHOS288gQ3pkI0ObGdgZsSg
# /ebpYp8c6txKWxqRKYDogVFp09CGBXyVqJ7vF0wIC80dlYMrUA2vRuKu488zktBY
# LdZPCuJkUMn+5I338OliKnQPBjIvbsAvmJKoFttbGcgCL+wW4Jw7AJrY826pomkm
# lBfLmB7Q1cNy7iEwz2LKxqI/yVmhrrzZYHjR/PNUCFrFby0NZX6N5Hzkp3ozL2p7
# kZcbFiLB0I10HCd2xnn1gL4M2ms6n/7y9yDnUsZ7t4NHcekKOchmIv0PfRKkfVaM
# RQ2yyXWZhlxSA78FZdanEjASwstLXrOasf/lKCty5S/Q+w==
# SIG # End signature block
