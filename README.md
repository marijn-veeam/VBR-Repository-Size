This Powershell scripts connects to the 



usage:
1) create credential file(s) using the create-cred-file.ps1 script. This script uses the credential object and serializes is to a file. This ensures the password file can only be opened on the same host by same user. Make at lease one credential file with the login and password for a VBR service account.
2) Set the required variables in the file vbrRepoSizesReporting-v1.x.ps1. main variable is the VBR FQDN.
3) run the script: .\vbrRepoSizesReporting-v1.0.ps1 .\password.cred to create the html report.

