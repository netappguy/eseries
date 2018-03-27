function Is-Numeric ($Value) {
    return $Value -match "^[\d\.]+$"
}

$username="rw"
$password="mypassword"

$secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($username, $secpasswd)
$eserie="myeseries.fqdn"
$protocol="https"
$port="443"
$api="/devmgr/v2/storage-systems"
$URI=$protocol+"://"+$eserie+":"+$port+$api

if ($protocol -eq "https")
{
add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
$AllProtocols = [System.Net.SecurityProtocolType]'Ssl3,Tls,Tls11,Tls12'
[System.Net.ServicePointManager]::SecurityProtocol = $AllProtocols
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username,$password)))
#"X-XSRF-TOKEN"="1mx20qvko7bepcjrxuiiuhs3t";
$header=@{"Authorization" = "Basic $base64AuthInfo" ;"Accept"="Application/Json"}
Try
{
	$connections=Invoke-WebRequest -Headers $header -Uri $URI -Method 'GET' -UseBasicParsing -SessionVariable websession
}
Catch
{
	"$_"
	throw ("Cannot get storage systems info from URI: '" + $URI + "'")
}
$Cookie=(($websession.Cookies.GetCookies($URI) | where {$_.Name -eq "JSESSIONID"}).Value)
$header=@{"Authorization" = "Basic $base64AuthInfo" ;"X-XSRF-TOKEN"=$Cookie;"Accept"="Application/Json"}

$StorageInfos=($connections | ConvertFrom-Json)

#[void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")        
#$jsonserial= New-Object -TypeName System.Web.Script.Serialization.JavaScriptSerializer 
#$jsonserial.MaxJsonLength = [int]::MaxValue
#$StorageInfo = $jsonserial.DeserializeObject($connections)
$start=0
set-content 'C:\Program Files\netApp\fix_sync_mirror.log' "Starting Log"
foreach ($StorageInfo in $StorageInfos)
{
	if (Is-Numeric $StorageInfo.Id)
	{
		#GET /storage-systems/{system-id}/controllers
		#This will return the list of controllers available on the system. You’ll need the ID’s in order to swap volume ownership.
		try
		{
			$Controllers=Invoke-WebRequest -Headers $header -Uri ($URI+"/"+$StorageInfo.Id+"/controllers") -Method 'GET' -UseBasicParsing
		}
		Catch
		{
			"$_"
			throw ("Cannot get controllers informations using uri: " + ($URI+"/"+$StorageInfo.Id+"/controllers"))
		}
		$Controllers=$Controllers | ConvertFrom-Json
		#GET /storage-systems/{id}/remote-mirror-pairs
		#This will be used to retrieve any defined mirror pairs.
		Try
		{
			$MirrorPairs=Invoke-WebRequest -Headers $header -Uri ($URI+"/"+$StorageInfo.Id+"/remote-mirror-pairs") -Method 'GET' -UseBasicParsing
		}
		Catch
		{
			"$_"
			throw ("Cannot login to " + ($URI+"/"+$StorageInfo.Id+"/remote-mirror-pairs"))
		}
		$MirrorPairs=($MirrorPairs | ConvertFrom-Json)
		foreach ($MirrorPair in $MirrorPairs)
		{
			
			#GET /storage-systems/{id}/remote-mirror-pairs/test-remote-mirror-communication/{mirrorId}
			#This will be used to perform the actual test for any mirrored volume pairs. They will need to be iterated over.
			$MirrorPairtest=Invoke-WebRequest -Headers $header -Uri ($URI+"/"+$StorageInfo.Id+"/remote-mirror-pairs/test-remote-mirror-communication/"+$MirrorPair.id) -Method 'GET' -UseBasicParsing
			$MirrorPairtestStatus=($MirrorPairtest| ConvertFrom-Json).status
			if ($MirrorPairtestStatus -eq "240")
			{
				write-host ("Changing volume '" + $MirrorPair.base.name + "' to controller with Serial # '" + (($Controllers | where {$_.id -notmatch $mirrorpair.base.currentControllerId}).serialNumber).trim() + "' (Controller " + ($Controllers | where {$_.id -notmatch $mirrorpair.base.currentControllerId}).physicalLocation.label + ")") -ForegroundColor Yellow
				
				$NextController=$Controllers.id | where {$_ -notmatch $mirrorpair.base.currentControllerId}
				$volchangeowner=@{"owningControllerId" = $NextController }
				$result=Invoke-WebRequest -Headers $header -Uri ($URI+"/"+$StorageInfo.Id+"/volumes/"+$mirrorpair.base.id) -Method POST -Body ($volchangeowner | ConvertTo-Json) -ContentType "Application/Json"
				if ($start -eq 0)
				{
					set-content 'C:\Program Files\netApp\revert.ps1' ("Invoke-WebRequest -Headers @{'Authorization' = 'Basic $base64AuthInfo' ;'X-XSRF-TOKEN'='$Cookie';'Accept'='Application/Json'} -Uri "+'"'+$URI + "/" +$StorageInfo.Id+"/volumes/"+$mirrorpair.base.id + '"'+' -Method POST -Body (@{"owningControllerId" = "' + $mirrorpair.base.currentControllerId +'"'+" } | ConvertTo-Json) -ContentType " +'"Application/Json"')
					$start++
				} else
				{
					add-content 'C:\Program Files\netApp\revert.ps1' ("Invoke-WebRequest -Headers @{'Authorization' = 'Basic $base64AuthInfo' ;'X-XSRF-TOKEN'='$Cookie';'Accept'='Application/Json'} -Uri "+'"'+$URI + "/" +$StorageInfo.Id+"/volumes/"+$mirrorpair.base.id + '"'+' -Method POST -Body (@{"owningControllerId" = "' + $mirrorpair.base.currentControllerId +'"'+" } | ConvertTo-Json) -ContentType " +'"Application/Json"')
				}
			} else
			{
				write-host ("Mirror from '" + $MirrorPair.base.name + "' to '" + $MirrorPair.target.name + "' is OK !") -ForegroundColor Green
				add-content 'C:\Program Files\netApp\fix_sync_mirror.log' ("Mirror from '" + $MirrorPair.base.name + "' to '" + $MirrorPair.target.name + "' is OK !")
			}
		}
	}
}
