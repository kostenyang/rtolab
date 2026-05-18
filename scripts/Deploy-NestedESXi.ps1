<#
.SYNOPSIS
    從 E:\<version>\ OVA 部署 4 台 nested ESXi 到外層 vCenter (vc-mgmt.vmware.taiwan),
    每版本一組 (5.2.1 / 9.0 / 9.1), 三版本平行部署 = 12 台 VM 同時上線.
    順便 enable MAC learning + ForgedTransmits 在 'trunk' portgroup (nested 需要).

.DESCRIPTION
    讀 inventory/lab.yaml 跟 inventory/secrets/lab.yaml (明文, .gitignore'd):
      - infra.outer_vcenter: 連 vCenter
      - infra.deployment: resource_pool / datastore / portgroup
      - artifacts.vcf_{90,91,521}.nested_esxi_ova: OVA 路徑
      - hosts_by_version[V]: 4 台主機 (fqdn, mgmt_ip)
      - vcf.versions[V].management_domain.tep_pool / network: 給 OVF DNS/NTP/gateway

    部署步驟 (per version, 三組平行):
      1. 連 outer vC
      2. 對 'trunk' portgroup 做 Set-VDSecurityPolicy + MAC learning (idempotent)
      3. 找 SELAB-Cluster 任一連線中的 host (給 Import-VApp 用)
      4. 對 4 台主機: 載入 OVF config -> 填 guestinfo -> Import-VApp (thin)
                      -> 拉大 cache/capacity 磁碟 -> Power on
      5. 完成

    建議: 第一次跑加 -WhatIf 先看會做什麼 + dump OVF property names.

.PARAMETER Versions
    要部哪幾個版本. 預設全部三版本.

.PARAMETER WhatIf
    Dry-run: 列出會部什麼, 印 OVF property names, 不真的 Import.

.PARAMETER GenerateBringupSpec
    完成後也跑 layer2-bringup/Generate-BringupSpec.ps1 -Version <V> 產 JSON.

.PARAMETER ThrottleLimit
    平行度. 預設 3 (一個版本一個 runspace).

.PARAMETER SkipMacLearningSetup
    跳過 portgroup MAC learning 設定 (如果 SELAB underlay 是 Sean 管的, 你不想動).

.EXAMPLE
    pwsh scripts\Deploy-NestedESXi.ps1 -WhatIf
    # 先看計畫

.EXAMPLE
    pwsh scripts\Deploy-NestedESXi.ps1 -GenerateBringupSpec
    # 真的部 12 台 + 順便產三份 bringup JSON
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [switch]   $WhatIf,
    [switch]   $GenerateBringupSpec,
    [int]      $ThrottleLimit = 3,
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
        # 全部走 ConfigSpec, 從頭建 (避免 clone 既有導致 BoolPolicy.Value 不能 set)
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

# ---- 建 deploy list (12 items) --------------------------------------------
$deployList = @()
foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''      # 9.0 -> 90, 5.2.1 -> 521
    $artKey = "vcf_$vKey"            # vcf_90, vcf_91, vcf_521
    $ovaPath = $inv.artifacts.$artKey.nested_esxi_ova
    if (-not $ovaPath -or -not (Test-Path $ovaPath)) {
        Write-Warning "skip version $v : OVA 找不到 ($ovaPath)"
        continue
    }
    foreach ($h in $inv.hosts_by_version[$v]) {
        $deployList += [pscustomobject]@{
            Version       = $v
            VKey          = $vKey
            OvaPath       = $ovaPath
            VMName        = $h.nested_vm_name        # e.g. vcf-m02-esx01-90
            Hostname      = $h.fqdn                  # kosten-vcf90-esx01.rtolab.local
            MgmtIp        = $h.mgmt_ip
            Netmask       = '255.255.255.0'
            Gateway       = $inv.network.mgmt.gateway
            MgmtVlan      = $inv.network.mgmt.vlan   # 114 — nested ESXi 自己 tag (因為 underlay 是 trunk)
            Dns           = $adIp
            Domain        = $domain
            Ntp           = $adIp
            EsxiPw        = $esxiPw
        }
    }
}

Write-Host ""
Write-Host "Deploy plan ($($deployList.Count) VMs, throttle=$ThrottleLimit):" -ForegroundColor Yellow
$deployList | Format-Table Version, VMName, Hostname, MgmtIp -AutoSize

# ---- WhatIf: dump OVF properties of first OVA per version + bye ----------
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

# ---- Disconnect 主 session, 讓 parallel runspace 自己 connect -------------
$vcCtx = @{ Fqdn=$vcFqdn; User=$vcUser; Pw=$vcPw }
$rpId  = $rp.Id
$dsId  = $ds.Id
$pgId  = $pg.Id
$hostNames = $availableHosts.Name
Disconnect-VIServer * -Confirm:$false -Force | Out-Null

# ---- 平行部 (per version) -------------------------------------------------
Write-Host ""
Write-Host "Starting parallel deploy (ThrottleLimit=$ThrottleLimit)..." -ForegroundColor Cyan
$deployList | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $item = $_
    $ctx  = $using:vcCtx
    $rpId = $using:rpId
    $dsId = $using:dsId
    $pgId = $using:pgId
    $hostNames = $using:hostNames

    Import-Module VMware.VimAutomation.Core
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

    function Write-DeployLog($msg, $color='White') {
        $ts = (Get-Date).ToString('HH:mm:ss')
        Write-Host "[$ts][$($item.Version)/$($item.VMName)] $msg" -ForegroundColor $color
    }

    try {
        Write-DeployLog "connecting vCenter..."
        Connect-VIServer $ctx.Fqdn -User $ctx.User -Password $ctx.Pw -ErrorAction Stop | Out-Null

        if (Get-VM -Name $item.VMName -ErrorAction SilentlyContinue) {
            Write-DeployLog "VM 已存在, skip" 'DarkYellow'
            return
        }

        $rp = Get-VIObjectByVIView -MORef $rpId
        $ds = Get-VIObjectByVIView -MORef $dsId
        $pg = Get-VIObjectByVIView -MORef $pgId
        $vmhost = Get-VMHost -Name ($hostNames | Get-Random) -ErrorAction Stop

        Write-DeployLog "loading OVF config..."
        $ovf = Get-OvfConfiguration -Ovf $item.OvaPath
        # 新 OVA 格式: guestinfo 是一個物件容器, sub-properties (hostname/ipaddress/...) 各自有 .Value
        $gi = $ovf.Common.guestinfo
        $gi.hostname.Value   = $item.Hostname
        $gi.ipaddress.Value  = $item.MgmtIp
        $gi.netmask.Value    = $item.Netmask
        $gi.gateway.Value    = $item.Gateway
        $gi.vlan.Value       = [string]$item.MgmtVlan      # nested ESXi 自己 tag 114 (underlay=trunk)
        $gi.dns.Value        = $item.Dns
        $gi.domain.Value     = $item.Domain
        $gi.ntp.Value        = $item.Ntp
        $gi.password.Value   = $item.EsxiPw
        $gi.ssh.Value        = 'True'
        if ($gi.PSObject.Properties['createvmfs']) { $gi.createvmfs.Value = 'False' }
        # NetworkMapping: 全部 -> trunk portgroup
        $ovf.NetworkMapping.VM_Network.Value = $pg

        Write-DeployLog "Import-VApp (thin, ~1GB OVA upload)..."
        $vapp = Import-VApp -Source $item.OvaPath -OvfConfiguration $ovf `
                            -Name $item.VMName -VMHost $vmhost -Datastore $ds `
                            -DiskStorageFormat Thin -Location $rp -Force -ErrorAction Stop

        $vm = if ($vapp -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VApp]) {
            $vapp | Get-VM
        } else { $vapp }

        # 拉大 disks (cache 100GB / capacity 700GB, thin 實際不佔)
        $disks = $vm | Get-HardDisk | Sort-Object Name
        if ($disks.Count -ge 3) {
            try {
                if ($disks[1].CapacityGB -lt 100) { Set-HardDisk -HardDisk $disks[1] -CapacityGB 100 -Confirm:$false | Out-Null; Write-DeployLog "  disk2 -> 100GB (cache)" }
                if ($disks[2].CapacityGB -lt 700) { Set-HardDisk -HardDisk $disks[2] -CapacityGB 700 -Confirm:$false | Out-Null; Write-DeployLog "  disk3 -> 700GB (capacity)" }
            } catch { Write-DeployLog "  disk resize failed: $($_.Exception.Message)" 'Yellow' }
        }

        Write-DeployLog "powering on..."
        $vm | Start-VM -Confirm:$false | Out-Null
        Write-DeployLog "✓ done" 'Green'
    } catch {
        Write-DeployLog "FAILED: $($_.Exception.Message)" 'Red'
    } finally {
        Disconnect-VIServer * -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host ""
Write-Host "All deploy jobs finished." -ForegroundColor Green

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
