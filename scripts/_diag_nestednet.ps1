$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
foreach($n in 'vcf-m02-esx01-91','vcf-m02-esx02-91','vcf-m02-esx03-91','vcf-m02-esx04-91'){
  $vm=Get-VM -Name $n -ErrorAction SilentlyContinue
  if(-not $vm){ Write-Host "$n NOT FOUND"; continue }
  Write-Host ("=== {0}  power={1}  esxihost={2} ===" -f $n,$vm.PowerState,$vm.VMHost.Name)
  Get-NetworkAdapter -VM $vm | ForEach-Object {
    Write-Host ("  {0,-16} pg={1,-32} connected={2} type={3} mac={4}" -f $_.Name,$_.NetworkName,$_.ConnectionState.Connected,$_.Type,$_.MacAddress)
  }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
