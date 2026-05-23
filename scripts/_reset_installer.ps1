<#  Hard-reset the VCF Installer VM (guest OS frozen, Tools dead).
    Uses ResetVM_Task (PowerCLI Restart-VM -Force). After reset, polls the
    Installer API until /v1/tokens responds, then prints current bringup state. #>
$ErrorActionPreference='Stop'
Import-Module powershell-yaml; Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repo='c:\Users\Administrator\rtolab'
$inv=Get-Content -Raw (Join-Path $repo 'inventory/lab.yaml') | ConvertFrom-Yaml
$sec=Get-Content -Raw (Join-Path $repo 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $sec.outer_vcenter.sso_admin_pw | Out-Null

$vm=Get-VM -Name 'vcf-installer-91'
$g=$vm.ExtensionData.Guest
Write-Host ("BEFORE: power={0} guestState={1} tools={2} heartbeat={3} ip={4}" -f $vm.PowerState,$g.GuestState,$g.ToolsRunningStatus,$vm.ExtensionData.GuestHeartbeatStatus,$g.IpAddress)

# Hard reset (ResetVM_Task) — guest is frozen, Tools dead, so no point in graceful shutdown.
Write-Host "Hard-resetting vcf-installer-91 ..."
Restart-VM -VM $vm -Confirm:$false | Out-Null
Start-Sleep 5
$vm=Get-VM -Name 'vcf-installer-91'
Write-Host ("AFTER reset cmd: power={0}" -f $vm.PowerState)
Disconnect-VIServer * -Confirm:$false -Force | Out-Null

# Wait for API to come back
$base='https://192.168.114.5'
$ok=$false
for($i=0;$i -lt 60;$i++){
  Start-Sleep 15
  try{
    $tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json) -TimeoutSec 20).accessToken
    if($tok){ $ok=$true; Write-Host ("  Installer API back after {0}s (token len={1})" -f (($i+1)*15),$tok.Length); break }
  }catch{
    Write-Host ("  attempt {0}: still down ({1})" -f ($i+1),$_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length)))
  }
}
if(-not $ok){ Write-Host "API never recovered within 15 min — investigate manually."; exit 1 }

# Fresh bringup status
$h=@{Authorization="Bearer $tok"}
$sddc=Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/sddcs/9ce45097-0fb3-42ec-910a-5171657ecfc8" -Headers $h -TimeoutSec 60
Write-Host ""
Write-Host ("=== bringup status: {0} ===" -f $sddc.status)
$subs=$sddc.sddcSubTasks
$done=($subs | Where-Object { $_.status -in 'SUCCESSFUL','COMPLETED' }).Count
$ip=($subs | Where-Object { $_.status -in 'IN_PROGRESS','RUNNING' })
$fail=($subs | Where-Object { $_.status -in 'FAILED','ERROR' })
$pend=($subs | Where-Object { $_.status -in 'PENDING' })
Write-Host ("subtasks: total={0} done={1} in_progress={2} failed={3} pending={4}" -f $subs.Count,$done,$ip.Count,$fail.Count,$pend.Count)
if($ip){ Write-Host "--- IN PROGRESS ---"; $ip | ForEach-Object { Write-Host ("  {0} / {1}" -f $_.milestoneTask,$_.name) } }
if($fail){ Write-Host "--- FAILED ---"; $fail | ForEach-Object { Write-Host ("  {0} / {1}" -f $_.milestoneTask,$_.name) } }
