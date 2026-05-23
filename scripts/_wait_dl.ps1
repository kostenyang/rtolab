<#  Wait for the 10 needed INSTALL bundles to all reach SUCCESSFUL.
    Re-triggers if any drop to FAILED. Exits when 10/10 ok. #>
$ErrorActionPreference='Continue'
$base='https://192.168.114.5'
$need=@(
 @{type='VSP';                ver='9.1.0.0.25370367'},
 @{type='VCENTER';            ver='9.1.0.0.25370922'},
 @{type='VCF_SALT';           ver='9.1.0.0.25346036'},
 @{type='SDDC_MANAGER';       ver='9.1.0.0.25371088'},
 @{type='VCF_FLEET_LCM';      ver='9.1.0.0.25371109'},
 @{type='VCF_SDDC_LCM';       ver='9.1.0.0.25371107'},
 @{type='NSX_T_MANAGER';      ver='9.1.0.0.25318225'},
 @{type='TELEMETRY_ACCEPTOR'; ver='9.1.0.0.25181946'},
 @{type='DEPOT_SERVICE';      ver='9.1.0.0.25371105'},
 @{type='VCF_SALT_RAAS';      ver='9.1.0.0.25346036'}
)
$start=Get-Date
$last=''
$retryBody=@{bundleDownloadSpec=@{downloadNow=$true}} | ConvertTo-Json
while($true){
  try{
    $tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json) -TimeoutSec 20).accessToken
    $h=@{Authorization="Bearer $tok"}
    $hP=@{Authorization="Bearer $tok";'Content-Type'='application/json'}
    $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h -TimeoutSec 30).elements
    $ok=0; $fail=0; $ip=0; $pend=0
    $bits=foreach($n in $need){
      $m=$b | Where-Object { $_.components | Where-Object { $_.type -eq $n.type -and $_.toVersion -eq $n.ver } } | Select-Object -First 1
      switch($m.downloadStatus){
        'SUCCESSFUL'        { $ok++;   "{0}=OK"   -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)) }
        'FAILED'            {
          $fail++
          # auto-retry on fail
          try{ Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri "$base/v1/bundles/$($m.id)" -Headers $hP -Body $retryBody -TimeoutSec 30 | Out-Null; "{0}=RETRY" -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)) }
          catch { "{0}=FAIL"  -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)) }
        }
        'VALIDATION_FAILED' { $fail++; "{0}=VAL_FAIL" -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)) }
        'IN_PROGRESS'       { $ip++;   "{0}=IP"   -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)) }
        default             { $pend++; "{0}={1}" -f $n.type.Substring(0,[Math]::Min(8,$n.type.Length)),$m.downloadStatus }
      }
    }
    $line=("ok={0,2} ip={1} pend={2} fail={3}  |  {4}" -f $ok,$ip,$pend,$fail,($bits -join ' '))
    if($line -ne $last){
      $el=((Get-Date)-$start).ToString('hh\:mm\:ss')
      Write-Host ("[$el] $line")
      $last=$line
    }
    if($ok -eq 10){ Write-Host ''; Write-Host '=== ALL 10 NEEDED BUNDLES SUCCESSFUL ==='; break }
  }catch{ Write-Host ("poll err: " + $_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length))) }
  Start-Sleep 60
}
