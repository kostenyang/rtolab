param([string]$Action='status',[string]$BundleId='')
$ErrorActionPreference='Stop'
$inst='192.168.114.5'
$base="https://$inst"
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok"}

if($Action -eq 'status'){
  $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
  $b | Group-Object downloadStatus | ForEach-Object { Write-Host ("{0,-14} {1}" -f $_.Name,$_.Count) }
  Write-Host "----"
  $b | Sort-Object downloadStatus,components | ForEach-Object {
    $comp=($_.components | ForEach-Object { $_.type }) -join ','
    $ver=($_.components | ForEach-Object { $_.toVersion }) -join ','
    Write-Host ("{0}  {1,-13} {2,-34} {3}" -f $_.id,$_.downloadStatus,$comp,$ver)
  }
}
elseif($Action -eq 'failed'){
  $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
  $b | Where-Object { $_.downloadStatus -in 'FAILED','VALIDATION_FAILED' } | ForEach-Object {
    $comp=($_.components | ForEach-Object { $_.type }) -join ','
    $ver=($_.components | ForEach-Object { $_.toVersion }) -join ','
    Write-Host ("{0}  {1,-34} {2}" -f $_.id,$comp,$ver)
  }
}
elseif($Action -eq 'trigger'){
  $body=@{bundleDownloadSpec=@{downloadNow=$true}}|ConvertTo-Json
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri "$base/v1/bundles/$BundleId" -Headers $h -ContentType 'application/json' -Body $body
  Write-Host "triggered $BundleId"
}
elseif($Action -eq 'triggerall'){
  $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
  $b | Where-Object { $_.downloadStatus -in 'FAILED','VALIDATION_FAILED' } | ForEach-Object {
    $comp=($_.components | ForEach-Object { $_.type }) -join ','
    if($comp -notmatch 'HCX|VCD_MIGRATION'){
      try{
        $body=@{bundleDownloadSpec=@{downloadNow=$true}}|ConvertTo-Json
        Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri "$base/v1/bundles/$($_.id)" -Headers $h -ContentType 'application/json' -Body $body | Out-Null
        Write-Host "triggered $($_.id)  $comp"
      }catch{ Write-Host "FAIL trigger $($_.id) $comp : $($_.Exception.Message)" }
    } else { Write-Host "skip   $($_.id)  $comp" }
  }
}
elseif($Action -eq 'one'){
  $r=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles/$BundleId" -Headers $h
  $r | ConvertTo-Json -Depth 8
}
elseif($Action -eq 'depot'){
  $r=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/system/settings/depot" -Headers $h
  $r | ConvertTo-Json -Depth 8
}
