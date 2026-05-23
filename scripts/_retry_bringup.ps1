param([string]$Id='8e0d3fc6-1d75-4a62-bcea-01f278f14800')
$ErrorActionPreference='Stop'
$base='https://192.168.114.5'
$spec=Get-Content -Raw layer2-bringup/vcf91/generated-bringup.json
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}
$uri="$base/v1/sddcs/$Id"+'?skipValidations=true'
try{
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri $uri -Headers $h -Body $spec
  Write-Host 'RETRY accepted'
  $r | Select-Object id,status,creationTimestamp | Format-List
}catch{
  Write-Host 'PATCH retry FAILED:'
  $resp=$_.Exception.Response
  if($resp){ $sr=New-Object IO.StreamReader($resp.GetResponseStream()); Write-Host $sr.ReadToEnd() } else { Write-Host $_.Exception.Message }
}
