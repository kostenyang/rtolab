<#  Wait for fresh VCF 9.1 Installer to come up, then point it at the
    offline depot 172.16.10.50:8888 and trigger metadata sync. #>
$ErrorActionPreference='Stop'
$base='https://192.168.114.5'
$depot='http://172.16.10.50:8888'

Write-Host "=== WAIT: Installer /v1/tokens (Photon firstboot ~5-10 min) ==="
$tok=$null
for($i=0;$i -lt 80;$i++){
  Start-Sleep 15
  try{
    $tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json) -TimeoutSec 20).accessToken
    if($tok){ Write-Host ("  Installer API up after {0}s (token len={1})" -f (($i+1)*15),$tok.Length); break }
  }catch{
    $m=$_.Exception.Message; if($m.Length -gt 80){$m=$m.Substring(0,80)}
    Write-Host ("  +{0,4}s  ..." -f (($i+1)*15)) -NoNewline
    Write-Host (" $m") -ForegroundColor DarkGray
  }
}
if(-not $tok){ Write-Host 'Installer API never came up within 20 min'; exit 1 }
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}

Write-Host ''
Write-Host '=== current depot config (should be empty) ==='
try{
  $cur=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/system/settings/depot" -Headers $h -TimeoutSec 30
  $cur | ConvertTo-Json -Depth 6 | Write-Host
}catch{ Write-Host "GET depot: $($_.Exception.Message)" }

Write-Host ''
Write-Host "=== PUT depot: offline at $depot ==="
$body=@{depotConfiguration=@{isOfflineDepot=$true;url=$depot}} | ConvertTo-Json -Depth 5
try{
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Put -Uri "$base/v1/system/settings/depot" -Headers $h -Body $body -TimeoutSec 60
  Write-Host 'PUT depot OK'
  $r | ConvertTo-Json -Depth 5 | Write-Host
}catch{
  Write-Host "PUT depot FAILED: $($_.Exception.Message)"
  $resp=$_.Exception.Response; if($resp){ $sr=New-Object IO.StreamReader($resp.GetResponseStream()); Write-Host $sr.ReadToEnd() }
  exit 1
}

Write-Host ''
Write-Host '=== PATCH depot-sync-info (trigger metadata sync) ==='
try{
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri "$base/v1/system/settings/depot/depot-sync-info" -Headers $h -TimeoutSec 60
  Write-Host 'sync triggered'
}catch{ Write-Host "sync trigger: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== poll sync status (up to 10 min) ==='
for($i=0;$i -lt 40;$i++){
  Start-Sleep 15
  try{
    $s=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/system/settings/depot/depot-sync-info" -Headers $h -TimeoutSec 30
    $st=$s.status
    Write-Host ("  +{0,4}s  status={1}" -f (($i+1)*15),$st)
    if($st -in 'SUCCESS','SUCCEEDED','COMPLETED'){ break }
    if($st -in 'FAILED','ERROR'){ $s | ConvertTo-Json -Depth 6 | Write-Host; break }
  }catch{ Write-Host ("  +{0,4}s  poll err: {1}" -f (($i+1)*15),$_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length))) }
}

Write-Host ''
Write-Host '=== bundles after sync ==='
try{
  $b=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/bundles" -Headers $h -TimeoutSec 60).elements
  $b | Group-Object downloadStatus | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Name,$_.Count) }
}catch{ Write-Host "GET bundles: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== DEPOT CONFIG DONE ==='
