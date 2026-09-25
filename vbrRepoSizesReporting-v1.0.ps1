<#
.SYNOPSIS
    This script gets all Repositories and makes a usage report.


.DESCRIPTION
    This script gets all repositories and makes a usage report. This report can optionally be e-mailed.
    
	make a credential file for a serviceaccount, use this file to connect to the VBR server.
	
    Known Limitations:
    - only shows performance and Capacity tiers.

    version 1.0

	todo:
	use Export-Clixml -InputObject $variable -Path ".\out.xml" for tracking data.


.EXAMPLE
    .\vbrRepoSizesReporting-v1.0.ps1 <rest_api_credential_file> <send_email_boolean> <email_credential_file>

.NOTES
    NAME: vbrRepoSizesReporting-v1.0.ps1
    VERSION: 1.0
    AUTHOR: Marijn Lebbink
    

#>
param (  
    [Parameter(Position=0,mandatory=$true)]
    [string]$restapi_cred,

    [Parameter(Position=1,mandatory=$false)]
    [bool]$send_mail = $false,

    [Parameter(Position=2,mandatory=$false)]
    [string]$mail_cred
)

$scriptversion = "1.0"

# ============================================================
# PARAMETERS - Report name / Units
# ============================================================
$storageUnit = "GiB" # supported values: GiB, TiB
$outfile = 'report.html'

# ============================================================
# PARAMETERS - Veeam Backup & Replication (REST API)
# ============================================================
$VeeamBaseUrl = "https://<vbr FQDN>:9419"
$apiVersion = "1.3-rev2"
$CertificateCheck = $false  # set $true if there is a valid certificate installed in VBR
$ReportName = "Repository Report"

# ============================================================
# PARAMETERS - Mail Server
# ============================================================
$from = 'user@fqdn'
$to = 'recipient@fqdn'
$smtpserver = 'smtp.mailserver.com'
$port = '25'
$subject = "Veeam $($ReportName)"


# ============================================================
# Config
# ============================================================

try {
    $ser_rest = Get-Content $restapi_cred
    $rest_cred = [System.Management.Automation.PSSerializer]::Deserialize($ser_rest)
}
catch {
    Write-host ("Loading rest api credentials failed: $($_.Exception.Message)")
    exit 1
}

if ($Args.Count -eq 2) {
    try {
        $ser_mail = Get-Content $mail_cred
        $email_cred = [System.Management.Automation.PSSerializer]::Deserialize($ser_mail)
    }
    catch {
        Write-host ("Loading rest api credentials failed: $($_.Exception.Message)")
        exit 1
    }
}


# ============================================================
# Code
# ============================================================


function Get-VeeamAccessToken {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $uri = "$BaseUrl/api/oauth2/token"
    $headers = @{
        "Content-Type" = "application/x-www-form-urlencoded"
        "Accept"       = "application/json"
        "x-api-version" = $apiVersion
    }
    $body = @{
        grant_type    = "password"
        username      = $Credential.UserName
        password      = $Credential.GetNetworkCredential().Password
        refresh_token = " "
        rememberMe    = " "
    }
    try {
        if ($CertificateCheck) { 
            $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body 
        }
        else {
            $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -SkipCertificateCheck 
        }
        
    }
    catch {
        Write-host ("Get-VeeamAccessToken failed: $($_.Exception.Message)")
        exit 1
    }
    return $resp.access_token
}

function Invoke-VeeamApiGet {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Path,   # e.g. "/api/v2.3/about"
        [Parameter(Mandatory)] [string] $Token
    )
    $headers = @{
        "Accept"        = "application/json"
        "Authorization" = "Bearer $Token"
        "x-api-version" = $apiVersion
    }
    try {
        if ($CertificateCheck) {
            return Invoke-RestMethod -Method Get -Uri ($BaseUrl + $Path) -Headers $headers
        }
        else {
            return Invoke-RestMethod -Method Get -Uri ($BaseUrl + $Path) -Headers $headers -SkipCertificateCheck
        }
    }
    catch {
        Write-host ("Invoke-VeeamApiGet failed: $($_.Exception.Message)")
        exit 1
    }
}


function logout {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Token
    )
    $headers = @{
        "Accept"        = "application/json"
        "Authorization" = "Bearer $Token"
        "x-api-version" = $apiVersion
    }
    try {
        if ($CertificateCheck) {
            Invoke-RestMethod -Method Post -Uri ($BaseUrl + "/api/oauth2/logout") -Headers $headers
        }
        else {
            Invoke-RestMethod -Method Post -Uri ($BaseUrl + "/api/oauth2/logout") -Headers $headers -SkipCertificateCheck
        }
    }
    catch {
        Write-host ("logout failed: $($_.Exception.Message)")
        exit 1
    }

}



# ============================================================
# Run
# ============================================================
$token = Get-VeeamAccessToken -BaseUrl $VeeamBaseUrl -Credential $rest_cred
$repos = Invoke-VeeamApiGet -BaseUrl $VeeamBaseUrl -Path "/api/v1/backupInfrastructure/repositories/states" -Token $token
$sobrs = Invoke-VeeamApiGet -BaseUrl $VeeamBaseUrl -Path "/api/v1/backupInfrastructure/scaleOutRepositories" -Token $token
logout -BaseUrl $VeeamBaseUrl -Token $token

$collectedData = @{"rows" = 0} # to store all repository data.
$repoSpace = @{}               # to store repository space info for quick lookup
foreach ($repo in $repos.data.GetEnumerator() ) { 
    $hostName = $repo.hostname
    $path = $repo.path 
    $type = $repo.type
    $repoName = $repo.name
    $capacityGB = $repo.capacityGB   # double
    $freeGB = $repo.freeGB           # double
    $usedSpaceGB = $repo.usedSpaceGB # double
    $percFree = [int](( $freeGB / $capacityGB ) * 100)
    $volume = ''
    $rpath = ''
	if ( @('WinLocal') -Contains $type ){  # driveletter:\<localpath> 
		$volume = $path.split('\')[0]
		$rpath = $path.Substring($volume.length)
	}
	elseif ( @('Smb') -Contains $type ){  # \\<sharehost>\<sharepath>
		$volume = $path.split('\')[2]
		$rpath = $path.Substring($volume.length+2)
	}
	elseif ( @('HPEStoreOnce','DellDataDomain') -Contains $type ){  # storeonce://<fqdn/ip>:CatalystStore01@/  or ddboost://DD01.usdemo.veeam.local:Repository@/
		$volume = ($path.split('/')[2]).split(':')[0]
		$rpath = ($path.split(':')[2])
		$rpath = $rpath.Substring(0, $rpath.length-2)
	}
	elseif ( @('S3Integrated','VeeamDataCloudVault','AmazonS3','S3Compatible') -Contains $type ){  #  amazonS3://<fqdn/ip>/<path>  or azureBlob://vdcvault<nr>/path or amazonS3://vdcvault<nr>/path
		$volume = $path.split('/')[2]
		$rpath = $path.Substring( ($path.indexof($volume) + $volume.length) )
	}
	else {                              # ie Linux  /<volume>/<path> 
		# check if volumes are mounted in /mnt if so include that in volume		
		$volume = $path.split('/')[1]
		if ( $volume -eq 'mnt' ) {
			$volume = $path.split('/')[1] + '/' + $path.split('/')[2]
		}
		$rpath = $path.Substring($volume.length+1)
	}
	# { hostName : { volume : { capacityGB , freeGB , percFree , 'repos' : { repo : { path , usedSpaceGB }}}}}
	if (-Not( $collectedData.Keys -Contains "$hostName" )){
		$collectedData.$hostName = @{"rows" = 0}
	}
	if (-Not( $collectedData.$hostName.Keys -Contains "$volume")) {
		$collectedData.$hostName.$volume = @{"rows" = 0}
		$collectedData.$hostName.$volume = @{"repos" = @{} }
	}
	$collectedData.$hostName.$volume.capacityGB = $capacityGB
	$collectedData.$hostName.$volume.freeGB = $freeGB
	$collectedData.$hostName.$volume.percFree = $percFree
	($collectedData.$hostName.$volume.repos)."$repoName" = @{"path" = $rpath ; "usedSpaceGB" = $usedSpaceGB}
	# update rows
	$collectedData.rows += 1
	$collectedData.$hostName.rows += 1
	$collectedData.$hostName.$volume.rows += 1
	# update quick lookup hash.
	$repoSpace.$repoName = @{ "capacityGB" = $capacityGB; "freeGB" = $freeGB; "usedSpaceGB" = $usedSpaceGB }
}

# Collect data for SOBR report.
$sobrData = @{'rows' = 0}
foreach ($sobr in $sobrs.data.GetEnumerator() ){
	$sobrName = $sobr.name
	if ( -Not ( $sobrData.Keys -Contains $sobrName )) {
		$sobrData.$sobrName = @{'performanceTier' = @() ; 'perfusedgb' = 0 ; 'capacityTier' = @() ; 'capusedgb' = 0; 'rows' = 0}
		# performanceTier
		foreach ( $repo in $sobr.performanceTier.performanceExtents.GetEnumerator() ){
			$reponame = $repo.name
			$sobrData.$sobrName.performanceTier += $reponame
			try {
				$sobrData.$sobrName.perfusedgb += $repoSpace.$reponame.usedSpaceGB
			}
			catch {
				Write-host ("Error adding usage data for performance $($reponame)")
			}
			$sobrData.rows += 1
			$sobrData.$sobrName.rows += 1
		}
		# CapacityTier
		# extents are repository ID's
		$token = Get-VeeamAccessToken -BaseUrl $VeeamBaseUrl -Credential $rest_cred
		foreach ( $repoID in $sobr.capacityTier.extents.GetEnumerator() ){
			$capRepo = Invoke-VeeamApiGet -BaseUrl $VeeamBaseUrl -Path "/api/v1/backupInfrastructure/repositories/$($repoID.id)" -Token $token
			$reponame = $capRepo.name
			$sobrData.$sobrName.capacityTier += $reponame
			try {
				$sobrData.$sobrName.capusedgb += $repoSpace.$reponame.usedSpaceGB
			}
			catch {
				Write-host ("Error adding usage data for capacity $($reponame)")
			}
			$sobrData.rows += 1
			$sobrData.$sobrName.rows += 1			
		}
		logout -BaseUrl $VeeamBaseUrl -Token $token
	}
}


# ============================================================
# build html report
# ============================================================

$html_start = "<!DOCTYPE html>
<html>
<head>
<style>
#report {
	font-family: Arial, Helvetica, sans-serif;
 	border-collapse: collapse;
 	width: 100%;
}

#report td, #report th {
 	border: 1px solid #ddd;
	padding: 8px;
}

#warn {
	background-color:red;
	text-align:right;
}

#right, #ok {
	text-align:right;
}

#grey {
	background-color: #f2f2f2;
}

#report tr:hover {background-color: #ddd;}

#report th {
	padding-top: 12px;
 	padding-bottom: 12px;
	text-align: left;
	background-color: #54b948;
	color: white;
}
</style>
</head>"

$html_body = "<body>
<h1>$($ReportName)</h1>
<h3>$((Get-Date).ToString(`"dd-MM-yyyy \/ HH:mm`"))</h3>
<table id=`"report`">
<tr>
	<th>Appliance</th>
	<th>Volume</th>
	<th>Capacity</th>
	<th colspan=`"2`">Free</th>
	<th>Repository</th>
	<th>Path</th>
	<th>Used</th>
</tr>`r`n"

$trCount = 0
$html_body += "<tr id=`"grey`">" # write first table row. 
# hostname loop
foreach ( $appliance in ($collectedData.Keys | sort ) ) { 
	if ($appliance -eq 'rows') {
		continue
	}
	# write td vor appliance with colspan = rows
	$html_body += "<td rowspan=`"$($collectedData.$appliance.rows)`">$($appliance)</td>`r`n"
	# volume-loop
	foreach ( $vol in $collectedData.$appliance.Keys ) {
		if ($vol -eq 'rows') {
			continue
		}
		$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">$($vol)</td>`r`n"
		if ( $collectedData.$appliance.$vol.capacityGB -eq -1) { # use infinity for unlimited cloud storage &infin; 
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">&infin;</td>`r`n"
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">&infin;</td>`r`n"
		}
		elseif ( $storageUnit -eq "GiB" ) {
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">$($collectedData.$appliance.$vol.capacityGB) GiB</td>`r`n"
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">$($collectedData.$appliance.$vol.freeGB) GiB</td>`r`n"
		}
		elseif ( $storageUnit -eq "TiB" ) {
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">$([math]::Round($collectedData.$appliance.$vol.capacityGB /1024 ,2)) TiB</td>`r`n"
			$html_body += "<td rowspan=`"$($collectedData.$appliance.$vol.rows)`">$([math]::Round($collectedData.$appliance.$vol.freeGB /1024 ,2)) TiB</td>`r`n"
		}		
		
		$free_perc = ''
		if ( $collectedData.$appliance.$vol.percFree -le 10 ){
			$free_perc = "id=`"warn`" "
		}
		$html_body += "<td $($free_perc)rowspan=`"$($collectedData.$appliance.$vol.rows)`">$($collectedData.$appliance.$vol.percFree)%</td>`r`n"
		#repo loop
		foreach ($repo in $collectedData.$appliance.$vol.repos.Keys ){
			$html_body += "<td>$($repo)</td>"
			$html_body += "<td>$($collectedData.$appliance.$vol.repos.$repo.path)</td>`r`n"
			if ( $storageUnit -eq "GiB" ) {
				$html_body += "<td>$($collectedData.$appliance.$vol.repos.$repo.usedSpaceGB) GiB</td>`r`n"
			}
			elseif ( $storageUnit -eq "TiB" ) {
				$html_body += "<td>$([math]::Round($collectedData.$appliance.$vol.repos.$repo.usedSpaceGB /1024 ,2)) TiB</td>`r`n"
			}			
			
			$html_body += "</tr>`r`n"
			$trCount += 1
			if ( $trCount -lt $collectedData.rows ) { # write new tr for next entry.
				if ( ($trCount % 2 ) -eq 0){
					$html_body += "<tr id=`"grey`">"
				}
				else {
					$html_body += "<tr>"
				}
			}
		}
	}
}
$html_body += "</table>"
if ( $sobrs.data.length -gt 0){
	$html_body += "<br><br>"
	$html_body += "<table id=`"report`">
    <tr>
        <th>SOBR</th>
        <th>Tier</th>
        <th>Used</th>
        <th>Capacity</th>
        <th colspan=`"2`">Free</th>
        <th>Repository</th>
    </tr>`r`n"
	$trCount = 0
    $sobrCount = 0
    $html_body += "<tr id=`"grey`">" # write first table row.
	foreach ( $sobr in ($sobrData.keys | sort )){
		if ( $sobr -eq 'rows'){
			continue
		}
		$html_body += "<td rowspan=`"$($sobrData.$sobr.rows)`"><strong>$($sobr)</strong></td>"

		# performance tier
		$sobrPerf_c = 0.0
        $sobrPerf_f = 0.0
		$sobrPerf_u = $false # check if there's a repo with "unlimited" storage. 
		$html_perf = ""
		$sobrPerf_rows = $sobrData.$sobr.performanceTier.count
		if ( $sobrPerf_rows -gt 0 ) {
			$repoCntr = 0
			# loop over all repo's in tier. Write html data in temp variable so we can attach after we used collected data.
			foreach ( $sobrRepo in $sobrData.$sobr.performanceTier ) {
				$sobrPerf_c += $repoSpace.$sobrRepo.capacityGB
				$sobrPerf_f += $repoSpace.$sobrRepo.freeGB
				if ($sobrPerf_c -lt 0) {
					$sobrPerf_u = $true	
				}
				$html_perf += "<td>$($sobrRepo)</td></tr>`r`n"
				$repoCntr += 1
				if ($repoCntr -lt $sobrPerf_rows){	# write <tr> if more repos. 
					if ( ($trCount % 2 ) -eq 0){
						$html_perf += "<tr id=`"grey`">"
					}
					else {
						$html_perf += "<tr>"
					}					
				}
			}
			$html_body += "<td rowspan=`"$($sobrPerf_rows)`">Performance</td>`r`n"	# tier
			if ( $storageUnit -eq "TiB" ) {
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$([math]::Round($sobrData.$sobr.perfusedgb /1024 ,2)) TiB</td>`r`n"	# used
			}
			else {
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$($sobrData.$sobr.perfusedgb) GiB</td>`r`n"	# used	
			}
			
			
			if ($sobrPerf_u) { 														# use infinity for unlimited cloud storage &infin; 
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">&infin;</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">&infin;</td>`r`n"	# Free				
			}
			elseif ( $storageUnit -eq "TiB" ) {	
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$([math]::Round($sobrPerf_c /1024 ,2)) TiB</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$([math]::Round($sobrPerf_f /1024, 2)) TiB</td>`r`n"	# Free
			}
			else {	
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$($sobrPerf_c) GiB</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrPerf_rows)`">$($sobrPerf_f) GiB</td>`r`n"	# Free
			}
			

			$sobrPerf_pc = [int](( $sobrPerf_f / $sobrPerf_c ) * 100)
			$free_perc = ''
			if ( $sobrPerf_pc -le 10 ){
				$free_perc = "id=`"warn`" "
			}
			$html_body += "<td $($free_perc)rowspan=`"$($sobrPerf_rows)`">$($sobrPerf_pc)%</td>`r`n"	# Free %
			$html_body += $html_perf
		}
		
		# Capacity tier
		$sobrCap_c = 0.0
        $sobrCap_f = 0.0
		$sobrCap_u = $false # check if there's a repo with "unlimited" storage. 
		$html_cap = ""
		$sobrCap_rows = $sobrData.$sobr.capacityTier.count
		if ( $sobrCap_rows -gt 0 ) {
			$repoCntr = 0
			# loop over all repo's in tier. Write html data in temp variable so we can attach after we used collected data.	
			foreach ( $sobrRepo in $sobrData.$sobr.capacityTier ) {
				$sobrCap_c += $repoSpace.$sobrRepo.capacityGB
				$sobrCap_f += $repoSpace.$sobrRepo.freeGB
				if ($sobrCap_c -lt 0) {
					$sobrCap_u = $true	
				}
				$html_cap += "<td>$($sobrRepo)</td><tr>`r`n"	
				$repoCntr += 1
				if ($repoCntr -lt $sobrPerf_rows){	# write <tr> if more repos. 
					if ( ($trCount % 2 ) -eq 0){
						$html_cap += "<tr id=`"grey`">"
					}
					else {
						$html_cap += "<tr>"
					}					
				}
			}
			$html_body += "<td rowspan=`"$($sobrCap_rows)`">Capacity</td>`r`n"	# tier
			
			if ( $storageUnit -eq "TiB" ) {
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$([math]::Round($sobrData.$sobr.capusedgb /1024 ,2)) GiB</td>`r`n"	# used
			}
			else {
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$($sobrData.$sobr.capusedgb) GiB</td>`r`n"	# used				
			}
			
			if ($sobrPerf_u) { 	
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">&infin;</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">&infin;</td>`r`n"	# Free
			}
			elseif ($storageUnit -eq "TiB" ) {
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$([math]::Round($sobrCap_c /1024, 2)) TiB</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$([math]::Round($sobrCap_f) /1024, 2)) TiB</td>`r`n"	# Free
			}
			else {
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$($sobrCap_c) GiB</td>`r`n"	# capacity
				$html_body += "<td rowspan=`"$($sobrCap_rows)`">$($sobrCap_f) GiB</td>`r`n"	# Free				
			}

			$sobrCap_pc = [int](( $sobrCap_f / $sobrCap_c ) * 100 )
			$free_perc = ''
			if ( $sobrCap_pc -le 10 ){
				$free_perc = "id=`"warn`" "
			}
			$html_body += "<td $($free_perc)rowspan=`"$($sobrCap_rows)`">$($sobrCap_pc)%</td>`r`n"	# Free %
			$html_body += $html_cap
		}

		$trCount += 1
	}
	$html_body += "</table>"
	$html_body += "<i>NOTE: Repositories can share volumes, SOBR free space might be shared with other SOBRs.<i><br><br>`r`n"
}

$html_body += "<i>script version $($scriptversion)</i>`r`n"
$html_end = "</body></html>"
$html = $html_start + $html_body + $html_end

# ============================================================
# save data in html or send pretty email
# ============================================================


if ($send_mail){
    if ($Args.Count -lt 2) {
        Send-MailMessage -From $from -To $to -Subject $subject -Body $html -SmtpServer $smtpserver -Port $port -BodyAsHtml
    }
    else {
        Send-MailMessage -From $from -To $to -Subject $subject -Body $html -SmtpServer $smtpserver -Port $port -Credential $mail_cred -BodyAsHtml
    }
}
else {
	$html | Set-Content $outfile
}