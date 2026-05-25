<#  Patch generated-bringup.json to add vcfAutomationSpec + vcfOperationsSpec
    + vcfOperationsCollectorSpec for Option B (full bringup with Automation+Ops). #>
$ErrorActionPreference='Stop'
$path='c:\Users\Administrator\rtolab\layer2-bringup\vcf91\generated-bringup.json'
$j=Get-Content -Raw $path | ConvertFrom-Json -Depth 50

# Add vcfAutomationSpec (required: hostname, internalClusterCidr)
# useExistingDeployment=true: tells validator we're reusing the VSP being deployed in same bringup
$auto=@{
  hostname              = 'kosten-vcf91-auto.rtolab.local'
  platformFqdn          = 'kosten-vcf91-vcfa-platform.rtolab.local'   # distinct from VSP's vspp (validator strict)
  adminUserPassword     = 'VMware1!VMware1!'   # 16 chars >= 15 min
  ipPool                = @('192.168.114.78','192.168.114.79','192.168.114.80','192.168.114.81','192.168.114.82','192.168.114.83')
  internalClusterCidr   = '172.27.0.0/16'
  nodePrefix            = 'vcfa'
  size                  = 'small'
  useExistingDeployment = $false
}
$j | Add-Member -NotePropertyName 'vcfAutomationSpec' -NotePropertyValue $auto -Force

# Add vcfOperationsSpec (required: nodes); omit version so Installer picks compatible build
$ops=@{
  nodes = @(
    @{
      hostname         = 'kosten-vcf91-ops.rtolab.local'
      rootUserPassword = 'VMware1!VMware1!'
      type             = 'master'
    }
  )
  adminUserPassword     = 'VMware1!VMware1!'
  applianceSize         = 'small'
  useExistingDeployment = $false
}
$j | Add-Member -NotePropertyName 'vcfOperationsSpec' -NotePropertyValue $ops -Force

# Add vcfOperationsCollectorSpec (required: hostname); omit version
$coll=@{
  hostname              = 'kosten-vcf91-ops-coll.rtolab.local'
  rootUserPassword      = 'VMware1!VMware1!'
  applianceSize         = 'small'
  useExistingDeployment = $false
}
$j | Add-Member -NotePropertyName 'vcfOperationsCollectorSpec' -NotePropertyValue $coll -Force

# Add licenseServerSpec (required: hostname)
$lic=@{
  hostname              = 'kosten-vcf91-lic.rtolab.local'
  version               = '9.1.0.0.25346031'
  useExistingDeployment = $false
}
$j | Add-Member -NotePropertyName 'licenseServerSpec' -NotePropertyValue $lic -Force

# Add vidbSpec (required: hostname)
$vidb=@{
  hostname = 'kosten-vcf91-vidb.rtolab.local'
  version  = '9.1.0.0.25368698'
  size     = 'small'
}
$j | Add-Member -NotePropertyName 'vidbSpec' -NotePropertyValue $vidb -Force

# Backup + write
Copy-Item $path "$path.bak-pre-auto-ops" -Force
$j | ConvertTo-Json -Depth 50 | Set-Content -Path $path -Encoding UTF8
Write-Host "spec patched. backup at $path.bak-pre-auto-ops"
Write-Host "new top-level keys:"
($j | Get-Member -MemberType NoteProperty | Sort-Object Name | Select-Object -ExpandProperty Name) | ForEach-Object { Write-Host "  $_" }
