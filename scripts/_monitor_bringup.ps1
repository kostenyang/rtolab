param([string]$SddcId='',[int]$Poll=90)
$ErrorActionPreference='Stop'
if(-not $SddcId){ $SddcId=(Get-Content -Raw scripts/_sddcid.txt).Trim() }
$base='https://192.168.114.5'
$last=''
while($true){
  try{
    $tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
    $h=@{Authorization="Bearer $tok"}
    $s=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/sddcs/$SddcId" -Headers $h
    $subs=$s.sddcSubTasks
    $done=($subs | Where-Object { $_.status -in 'SUCCESSFUL','COMPLETED' }).Count
    $tot=$subs.Count
    $cur=($subs | Where-Object { $_.status -in 'IN_PROGRESS','RUNNING' } | Select-Object -First 1)
    $fail=($subs | Where-Object { $_.status -in 'FAILED','ERROR' })
    $curtxt=if($cur){ "$($cur.milestoneTask) / $($cur.name)" }else{ '' }
    $line=("{0}  status={1}  subtasks={2}/{3}  cur=[{4}]" -f (Get-Date -Format 'HH:mm:ss'),$s.status,$done,$tot,$curtxt)
    if($line -ne $last){ Write-Host $line; $last=$line }
    if($fail){ Write-Host "FAILED subtasks:"; $fail | ForEach-Object { Write-Host ("  - {0} / {1}" -f $_.milestoneTask,$_.name) } }
    if($s.status -notin 'IN_PROGRESS','PENDING','RUNNING'){
      Write-Host "FINAL status: $($s.status)"
      break
    }
  }catch{ Write-Host ("{0}  poll error: {1}" -f (Get-Date -Format 'HH:mm:ss'),$_.Exception.Message) }
  Start-Sleep $Poll
}
