<#
.SYNOPSIS
    This script creates credential file for securely storing username and password.


.DESCRIPTION
    This script creates credential file for securely storing username and password. The .cred file can be used in other scripts.
    Make sure to run this file on the _same_ system and with the _same_ user as will be using the credential file.
    The 

.EXAMPLE
    .\create-cred-file.ps1

.NOTES
    NAME: create-cred-file.ps1
    VERSION: 1
    AUTHOR: Marijn Lebbink
    
#>
param (  
    [Parameter(Mandatory=$false)]
    [string]$outfile = "password.cred"
)

$cred = Get-Credential -Message "Please enter Username and Password to store in $($outfile)"

[System.Management.Automation.PSSerializer]::Serialize($cred) | Set-Content $outfile