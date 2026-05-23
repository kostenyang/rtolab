<#  Submit a fresh VCF 9.1 management-domain bringup (POST /v1/sddcs)
    to the existing VCF Installer at 192.168.114.5.
    Saves the new sddcId to scripts/_sddcid.txt. #>
$ErrorActionPreference='Stop'
$base='https://192.168.114.5'
$spec=Get-Content -Raw layer2-bringup/vcf91/generated-bringup.json
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}
try{
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/sddcs" -Headers $h -Body $spec
  Write-Host 'BRINGUP SUBMITTED'
  $r | Select-Object id,status,creationTimestamp | Format-List
  if($r.id){ $r.id | Set-Content -NoNewline scripts/_sddcid.txt; Write-Host "sddcId saved -> scripts/_sddcid.txt" }
}catch{
  Write-Host 'POST /v1/sddcs FAILED:'
  $resp=$_.Exception.Response
  if($resp){ $sr=New-Object IO.StreamReader($resp.GetResponseStream()); Write-Host $sr.ReadToEnd() } else { Write-Host $_.Exception.Message }
  exit 1
}
