param([string]$SpecFile='layer2-bringup/vcf91/generated-bringup.json',[string]$ValId='')
$ErrorActionPreference='Stop'
$base='https://192.168.114.5'
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}

if(-not $ValId){
  $spec=Get-Content -Raw $SpecFile
  try{
    $r=Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/sddcs/validations" -Headers $h -Body $spec
  }catch{
    Write-Host "POST validation FAILED:" -ForegroundColor Red
    $resp=$_.Exception.Response
    if($resp){ $sr=New-Object IO.StreamReader($resp.GetResponseStream()); Write-Host $sr.ReadToEnd() }
    else { Write-Host $_.Exception.Message }
    exit 1
  }
  $ValId=$r.id
  Write-Host "validation id: $ValId"
}
do{
  Start-Sleep 12
  $v=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/sddcs/validations/$ValId" -Headers $h
  Write-Host ("  {0}" -f $v.executionStatus)
}while($v.executionStatus -in 'IN_PROGRESS','PENDING')

Write-Host ""
Write-Host ("execStatus={0}  resultStatus={1}" -f $v.executionStatus,$v.resultStatus)
Write-Host "==== ALL CHECKS ===="
foreach($c in $v.validationChecks){
  Write-Host ("[{0,-10}] {1}" -f $c.resultStatus,$c.description)
  if($c.resultStatus -ne 'SUCCEEDED' -and $c.errorResponse){
    Write-Host ("            -> {0}" -f ($c.errorResponse | ConvertTo-Json -Depth 6 -Compress))
  }
  if($c.resultStatus -ne 'SUCCEEDED' -and $c.nestedValidationChecks){
    foreach($n in $c.nestedValidationChecks){
      if($n.resultStatus -ne 'SUCCEEDED'){ Write-Host ("            * [{0}] {1}" -f $n.resultStatus,$n.description) }
    }
  }
}
$ValId | Set-Content -NoNewline scripts/_lastvalid.txt
