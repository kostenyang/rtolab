<#  Trigger download of bundles from offline depot to Installer local cache.
    Default: only INSTALL imageType bundles (greenfield install needs).
    Use -AllPending to also pull PATCH bundles. #>
param([switch]$AllPending)
$ErrorActionPreference='Stop'
$base='https://192.168.114.5'
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}

$b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
if($AllPending){
  $todo=$b | Where-Object { $_.downloadStatus -eq 'PENDING' }
}else{
  $todo=$b | Where-Object {
    $_.downloadStatus -eq 'PENDING' -and ($_.components | Where-Object { $_.imageType -eq 'INSTALL' })
  }
}
Write-Host ("triggering {0} bundles ..." -f $todo.Count)
foreach($x in $todo){
  $c=$x.components | Select -First 1
  try{
    $body=@{bundleDownloadSpec=@{downloadNow=$true}} | ConvertTo-Json
    Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri "$base/v1/bundles/$($x.id)" -Headers $h -Body $body -TimeoutSec 60 | Out-Null
    Write-Host ("  + {0,-30} {1,-22} {2}" -f $c.type,$c.toVersion,$x.id.Substring(0,8))
  }catch{
    Write-Host ("  ! {0,-30} {1,-22} FAIL: {2}" -f $c.type,$c.toVersion,$_.Exception.Message)
  }
}

Write-Host ''
Write-Host '=== polling download progress (max 30 min) ==='
for($i=0;$i -lt 60;$i++){
  Start-Sleep 30
  $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
  $ids=$todo | ForEach-Object { $_.id }
  $mine=$b | Where-Object { $ids -contains $_.id }
  $grp=$mine | Group-Object downloadStatus
  $summary=($grp | ForEach-Object { "{0}={1}" -f $_.Name,$_.Count }) -join ' '
  Write-Host ("  +{0,4}s  {1}" -f (($i+1)*30),$summary)
  $left=($mine | Where-Object { $_.downloadStatus -in 'PENDING','SCHEDULED','IN_PROGRESS','DOWNLOADING','VALIDATING' }).Count
  if($left -eq 0){ Write-Host '  all done'; break }
}

Write-Host ''
Write-Host '=== final state of triggered bundles ==='
$b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h).elements
$ids=$todo | ForEach-Object { $_.id }
$mine=$b | Where-Object { $ids -contains $_.id }
$mine | Group-Object downloadStatus | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Name,$_.Count) }
$fail=$mine | Where-Object { $_.downloadStatus -in 'FAILED','VALIDATION_FAILED' }
if($fail){
  Write-Host ''
  Write-Host '=== FAILED bundles ==='
  $fail | ForEach-Object {
    $c=$_.components | Select -First 1
    Write-Host ("  ! {0,-30} {1,-22} {2}" -f $c.type,$c.toVersion,$_.id.Substring(0,8))
  }
}
