<#
.SYNOPSIS
    從 E:\<version>\ OVA 部署 4 台 nested ESXi 到外層 vCenter (vc-mgmt.vmware.taiwan),
    每版本一組 (5.2.1 / 9.0 / 9.1), sequential per-version, 共 12 台 VM.
    VMs 分到 vApp: rtolab-vcf90 / rtolab-vcf91 / rtolab-vcf521.
    順便 enable Promiscuous + ForgedTransmits + MacChanges + MAC learning 在
    'trunk' portgroup (nested 需要).

.DESCRIPTION
    讀 inventory/lab.yaml 跟 inventory/secrets/lab.yaml (明文, .gitignore'd):
      - infra.outer_vcenter: 連 vCenter
      - infra.deployment: resource_pool / datastore / portgroup
      - artifacts.vcf_{90,91,521}.nested_esxi_ova: OVA 路徑
      - hosts_by_version[V]: 4 台主機 (fqdn, mgmt_ip)

    一次跑 12 台 sequential (~40 sec/台, 約 8-10 分鐘). 之前嘗試平行,
    但 PowerCLI 跨 runspace 的 Disconnect-VIServer * 會踢別 runspace
    的 session, 最後一台常 fail. 換成同 session sequential 之後穩.

    建議: 第一次跑加 -WhatIf 看 OVF properties + 計畫.

.PARAMETER Versions
    要部哪幾個版本. 預設全部三版本.

.PARAMETER WhatIf
    Dry-run: 列計畫 + 印 OVF property names, 不真的 Import.

.PARAMETER GenerateBringupSpec
    完成後也跑 layer2-bringup/vcf<V>/Generate-BringupSpec.ps1 產 JSON.

.PARAMETER SkipMacLearningSetup
    跳過 portgroup MAC learning 設定 (SELAB underlay 是 Sean 管的, 你不想動).

.EXAMPLE
    pwsh scripts\Deploy-NestedESXi.ps1 -WhatIf
    pwsh scripts\Deploy-NestedESXi.ps1 -GenerateBringupSpec
    pwsh scripts\Deploy-NestedESXi.ps1 -Versions 9.1     # 只部 9.1 (補單台等)
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [switch]   $WhatIf,
    [switch]   $GenerateBringupSpec,
    [switch]   $SkipMacLearningSetup
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

# ---- 模組 -----------------------------------------------------------------
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

# ---- 讀 inventory + secrets -----------------------------------------------
$inv = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secretsFile = Join-Path $repoRoot 'inventory/secrets/lab.yaml'
if (-not (Test-Path $secretsFile)) { throw "Secrets 不存在: $secretsFile" }
$secrets = Get-Content -Raw $secretsFile | ConvertFrom-Yaml

$vcFqdn   = $inv.infra.outer_vcenter.fqdn
$vcUser   = $inv.infra.outer_vcenter.user
$vcPw     = $secrets.outer_vcenter.sso_admin_pw
$cluster  = $inv.infra.outer_vcenter.cluster
$rpName   = $inv.infra.deployment.resource_pool
$dsName   = $inv.infra.deployment.datastore
$pgName   = $inv.infra.deployment.portgroup
$esxiPw   = $secrets.esxi.root_pw
$adIp     = $inv.infra.ad_dns.ip
$domain   = $inv.lab.domain

# ---- 連 outer vC + 驗 inventory -------------------------------------------
Write-Host "Connecting $vcFqdn ..." -ForegroundColor Cyan
Connect-VIServer $vcFqdn -User $vcUser -Password $vcPw -ErrorAction Stop | Out-Null

$rp = Get-ResourcePool -Name $rpName -ErrorAction Stop
$ds = Get-Datastore   -Name $dsName -ErrorAction Stop
$pg = Get-VDPortgroup -Name $pgName -ErrorAction Stop
$cl = Get-Cluster     -Name $cluster -ErrorAction Stop
$availableHosts = $cl | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' }
if (-not $availableHosts) { throw "Cluster $cluster 沒有可用 host" }

Write-Host ("  RP: {0} | DS: {1} (free {2:N0}GB) | PG: {3} | hosts available: {4}" -f `
            $rp.Name, $ds.Name, $ds.FreeSpaceGB, $pg.Name, $availableHosts.Count) -ForegroundColor Green

# ---- MAC learning + ForgedTransmits on portgroup --------------------------
if (-not $SkipMacLearningSetup) {
    Write-Host ""
    Write-Host "Configuring portgroup '$pgName' (ForgedTransmits + MacChanges + MAC learning)..." -ForegroundColor Cyan
    if ($WhatIf) {
        Write-Host "  (WhatIf) would set ForgedTransmits=True, MacChanges=True, MacLearningPolicy.Enabled=True" -ForegroundColor DarkGray
    } else {
        $view = Get-View $pg
        $bpTrue = { New-Object VMware.Vim.BoolPolicy -Property @{ Value = $true } }
        $spec = New-Object VMware.Vim.DVPortgroupConfigSpec -Property @{
            ConfigVersion = $view.Config.ConfigVersion
            DefaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting -Property @{
                MacManagementPolicy = New-Object VMware.Vim.DVSMacManagementPolicy -Property @{
                    AllowPromiscuous  = & $bpTrue
                    ForgedTransmits   = & $bpTrue
                    MacChanges        = & $bpTrue
                    MacLearningPolicy = New-Object VMware.Vim.DVSMacLearningPolicy -Property @{
                        Enabled              = $true
                        AllowUnicastFlooding = $true
                        Limit                = 4096
                        LimitPolicy          = 'DROP'
                    }
                }
            }
        }
        $taskRef = $view.ReconfigureDVPortgroup_Task($spec)
        $taskView = Get-View $taskRef
        while ($taskView.Info.State -in 'running','queued') {
            Start-Sleep 1
            $taskView.UpdateViewData('Info.State','Info.Error')
        }
        if ($taskView.Info.State -ne 'success') {
            throw "Reconfigure portgroup '$pgName' failed: $($taskView.Info.Error.LocalizedMessage)"
        }
        Write-Host "  ✓ Portgroup '$pgName' updated (Prom/ForgedTransmits/MacChanges + MAC learning ON)" -ForegroundColor Green
    }
}

# ---- 建 deploy list -------------------------------------------------------
$deployList = @()
foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    $artKey = "vcf_$vKey"
    $ovaPath = $inv.artifacts.$artKey.nested_esxi_ova
    if (-not $ovaPath -or -not (Test-Path $ovaPath)) {
        Write-Warning "skip version $v : OVA 找不到 ($ovaPath)"
        continue
    }
    # Per-version sizing (預設 12 vCPU / 96GB; 各版本可在 inventory 覆蓋)
    $sz = $inv.vcf.versions[$v].sizing
    $vcpu = if ($sz -and $sz.vcpu)      { [int]$sz.vcpu }      else { 12 }
    $mem  = if ($sz -and $sz.memory_gb) { [int]$sz.memory_gb } else { 96 }
    foreach ($h in $inv.hosts_by_version[$v]) {
        $deployList += [pscustomobject]@{
            Version       = $v
            VKey          = $vKey
            OvaPath       = $ovaPath
            VMName        = $h.nested_vm_name
            Hostname      = $h.fqdn
            MgmtIp        = $h.mgmt_ip
            Netmask       = '255.255.255.0'
            Gateway       = $inv.network.mgmt.gateway
            MgmtVlan      = $inv.network.mgmt.vlan
            Dns           = $adIp
            Domain        = $domain
            Ntp           = $adIp
            EsxiPw        = $esxiPw
            VCpu          = $vcpu
            MemGB         = $mem
        }
    }
}

Write-Host ""
Write-Host "Deploy plan ($($deployList.Count) VMs, sequential per version):" -ForegroundColor Yellow
$deployList | Format-Table Version, VMName, Hostname, MgmtIp -AutoSize

# ---- WhatIf: dump OVF properties + bye -----------------------------------
if ($WhatIf) {
    Write-Host ""
    Write-Host "(WhatIf) OVF property names per OVA:" -ForegroundColor Cyan
    foreach ($v in $Versions) {
        $vKey = $v -replace '\.',''
        $ovaPath = $inv.artifacts."vcf_$vKey".nested_esxi_ova
        if (-not (Test-Path $ovaPath)) { continue }
        Write-Host "  --- $v ($ovaPath) ---" -ForegroundColor Yellow
        $ovf = Get-OvfConfiguration -Ovf $ovaPath
        $ovf | Format-List
    }
    Disconnect-VIServer * -Confirm:$false -Force | Out-Null
    return
}

# ---- Sequential deploy: 一版接一版, 同個 vC session, 不會搶 --------------
Write-Host ""
Write-Host "Starting per-version sequential deploy..." -ForegroundColor Cyan

function Write-DeployLog($msg, $color='White', $tag='') {
    $ts = (Get-Date).ToString('HH:mm:ss')
    $prefix = if ($tag) { "[$tag] " } else { '' }
    Write-Host "[$ts]$prefix$msg" -ForegroundColor $color
}

$grouped = $deployList | Group-Object Version
foreach ($group in $grouped) {
    $version = $group.Name
    $items   = $group.Group
    $vKey    = $version -replace '\.',''
    $vappName = "rtolab-vcf$vKey"

    # 找/建 vApp 在 Kosten RP 下
    $deployVapp = Get-VApp -Name $vappName -ErrorAction SilentlyContinue
    if (-not $deployVapp) {
        Write-DeployLog "creating vApp '$vappName' under RP '$($rp.Name)'..." 'Cyan' $version
        $deployVapp = New-VApp -Name $vappName -Location $rp
    } else {
        Write-DeployLog "vApp '$vappName' 已存在, 重用" 'DarkGray' $version
    }

    foreach ($item in $items) {
        $vmTag = "$version/$($item.VMName)"
        try {
            if (Get-VM -Name $item.VMName -ErrorAction SilentlyContinue) {
                Write-DeployLog "VM exists, skip" 'DarkYellow' $vmTag
                continue
            }
            $vmhost = Get-VMHost -Name (@($availableHosts.Name) | Get-Random) -ErrorAction Stop

            Write-DeployLog "loading OVF + setting guestinfo..." 'White' $vmTag
            $ovf = Get-OvfConfiguration -Ovf $item.OvaPath
            $gi = $ovf.Common.guestinfo
            $gi.hostname.Value   = $item.Hostname
            $gi.ipaddress.Value  = $item.MgmtIp
            $gi.netmask.Value    = $item.Netmask
            $gi.gateway.Value    = $item.Gateway
            $gi.vlan.Value       = [string]$item.MgmtVlan
            $gi.dns.Value        = $item.Dns
            $gi.domain.Value     = $item.Domain
            $gi.ntp.Value        = $item.Ntp
            $gi.password.Value   = $item.EsxiPw
            $gi.ssh.Value        = 'True'
            if ($gi.PSObject.Properties['createvmfs']) { $gi.createvmfs.Value = 'False' }
            $ovf.NetworkMapping.VM_Network.Value = $pg

            Write-DeployLog "Import-VApp (thin, ~1GB upload) into vApp '$vappName'..." 'White' $vmTag
            $vapp = Import-VApp -Source $item.OvaPath -OvfConfiguration $ovf `
                                -Name $item.VMName -VMHost $vmhost -Datastore $ds `
                                -DiskStorageFormat Thin -Location $deployVapp -Force -ErrorAction Stop

            $vm = if ($vapp -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VApp]) { $vapp | Get-VM } else { $vapp }

            # 拉大 CPU / RAM (OVA default ~2 vCPU/8GB 太小, VCF nested 要 12-24/96)
            Write-DeployLog "  resize: $($vm.NumCpu) vCPU / $($vm.MemoryGB) GB -> $($item.VCpu) vCPU / $($item.MemGB) GB" 'DarkGray' $vmTag
            Set-VM -VM $vm -NumCpu $item.VCpu -MemoryGB $item.MemGB -Confirm:$false | Out-Null

            $disks = $vm | Get-HardDisk | Sort-Object Name
            if ($disks.Count -ge 3) {
                try {
                    if ($disks[1].CapacityGB -lt 100) { Set-HardDisk -HardDisk $disks[1] -CapacityGB 100 -Confirm:$false | Out-Null; Write-DeployLog "  disk2 -> 100GB (cache)" 'DarkGray' $vmTag }
                    if ($disks[2].CapacityGB -lt 700) { Set-HardDisk -HardDisk $disks[2] -CapacityGB 700 -Confirm:$false | Out-Null; Write-DeployLog "  disk3 -> 700GB (capacity)" 'DarkGray' $vmTag }
                } catch { Write-DeployLog "  disk resize failed: $($_.Exception.Message)" 'Yellow' $vmTag }
            }

            Write-DeployLog "powering on..." 'White' $vmTag
            $vm | Start-VM -Confirm:$false | Out-Null
            Write-DeployLog "✓ done" 'Green' $vmTag
        } catch {
            Write-DeployLog "FAILED: $($_.Exception.Message)" 'Red' $vmTag
        }
    }
    Write-DeployLog "version $version deploy loop done" 'Cyan' $version
}

Disconnect-VIServer * -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null

Write-Host ""
Write-Host "All deploy loops finished." -ForegroundColor Green

# ---- Optionally: generate bringup JSON files (per-version self-contained) -
if ($GenerateBringupSpec) {
    foreach ($v in $Versions) {
        $vKey = $v -replace '\.',''
        $vGen = Join-Path $repoRoot "layer2-bringup/vcf$vKey/Generate-BringupSpec.ps1"
        $vOut = Join-Path $repoRoot "layer2-bringup/vcf$vKey/generated-bringup.json"
        if (-not (Test-Path $vGen)) { Write-Warning "skip $v : $vGen not found"; continue }
        Write-Host ""
        Write-Host "Generating bringup spec for $v -> $vOut ..." -ForegroundColor Cyan
        & $vGen -LabMode -OutputFile $vOut
    }
}

Write-Host ""
Write-Host "下一步: 等 nested ESXi boot (~5-10 min), 然後 Layer 1 prep:" -ForegroundColor Cyan
Write-Host "  pwsh .\layer1-nested\Prepare-NestedESXi.ps1"
