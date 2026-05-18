<#
.SYNOPSIS
    建 12 台 nested ESXi VMs 到 vc-mgmt.vmware.taiwan (4×3 versions, 每版本一個 vApp).
    **From-scratch build (不用 OVA)** — 規格抄 SELAB Sean 的 ESXi9-01 reference:
      GuestId=vmkernel7Guest, HwVer=vmx-19, Firmware=efi, SecureBoot=false
      PVSCSI controller -> Disk 1 10GB (boot, blank) on SCSI
      NVMe controller   -> Disk 2 (cache, 100GB) + Disk 3 (capacity, 700GB)
      IDE 0 CD-ROM with ESXi installer ISO mounted (UEFI-boots installer)
      2x Vmxnet3 NICs on 'trunk' portgroup
      ExtraConfig: monitor.phys_bits_used = 45 (nested 需要)
    BootOrder = [Cdrom, Disk1] so ESXi installer ISO runs first, falls
    back to disk 1 after install completes & reboots.

    用 OVA 的失敗教訓 (見 git log): William Lam 的 "Appliance Template" OVA
    把 disk 1 跟 ESXi 預裝在 NVMe + BIOS/MBR 格式. 外層 vCenter 7.0u3 用 EFI
    firmware 找不到 disk 1 的 EFI System Partition -> 卡 Boot Manager.
    Fresh-build + ESXi installer ISO -> installer 會自己建正確的 ESP. ✓

.DESCRIPTION
    讀 inventory/lab.yaml 跟 inventory/secrets/lab.yaml.
    -GenerateBringupSpec 也跑各版本 generator 出 JSON.

.EXAMPLE
    pwsh scripts\Deploy-NestedESXi.ps1 -GenerateBringupSpec
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
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
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

$vcFqdn  = $inv.infra.outer_vcenter.fqdn
$vcUser  = $inv.infra.outer_vcenter.user
$vcPw    = $secrets.outer_vcenter.sso_admin_pw
$cluster = $inv.infra.outer_vcenter.cluster
$rpName  = $inv.infra.deployment.resource_pool
$dsName  = $inv.infra.deployment.datastore
$pgName  = $inv.infra.deployment.portgroup

# ---- 連 outer vC ---------------------------------------------------------
Write-Host "Connecting $vcFqdn ..." -ForegroundColor Cyan
Connect-VIServer $vcFqdn -User $vcUser -Password $vcPw -ErrorAction Stop | Out-Null

$rp = Get-ResourcePool -Name $rpName -ErrorAction Stop
$ds = Get-Datastore   -Name $dsName -ErrorAction Stop
$pg = Get-VDPortgroup -Name $pgName -ErrorAction Stop
$cl = Get-Cluster     -Name $cluster -ErrorAction Stop
$availableHosts = $cl | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' }
Write-Host ("  RP: {0} | DS: {1} (free {2:N0}GB) | PG: {3} | hosts: {4}" -f $rp.Name, $ds.Name, $ds.FreeSpaceGB, $pg.Name, $availableHosts.Count) -ForegroundColor Green

# ---- MAC learning + ForgedTransmits on trunk portgroup (idempotent) -------
if (-not $SkipMacLearningSetup) {
    Write-Host ""
    Write-Host "Configuring portgroup '$pgName' (ForgedTransmits + MacChanges + MAC learning)..." -ForegroundColor Cyan
    $view = Get-View $pg
    $bpTrue = { New-Object VMware.Vim.BoolPolicy -Property @{ Value = $true } }
    $cfgSpec = New-Object VMware.Vim.DVPortgroupConfigSpec -Property @{
        ConfigVersion = $view.Config.ConfigVersion
        DefaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting -Property @{
            MacManagementPolicy = New-Object VMware.Vim.DVSMacManagementPolicy -Property @{
                AllowPromiscuous  = & $bpTrue
                ForgedTransmits   = & $bpTrue
                MacChanges        = & $bpTrue
                MacLearningPolicy = New-Object VMware.Vim.DVSMacLearningPolicy -Property @{
                    Enabled = $true; AllowUnicastFlooding = $true; Limit = 4096; LimitPolicy = 'DROP'
                }
            }
        }
    }
    $taskRef = $view.ReconfigureDVPortgroup_Task($cfgSpec)
    $tv = Get-View $taskRef
    while ($tv.Info.State -in 'running','queued') { Start-Sleep 1; $tv.UpdateViewData('Info.State','Info.Error') }
    if ($tv.Info.State -ne 'success') { throw "Portgroup reconfig failed: $($tv.Info.Error.LocalizedMessage)" }
    Write-Host "  ✓ Portgroup '$pgName' MAC learning + ForgedTransmits ON" -ForegroundColor Green
}

# ---- 建 deploy list -------------------------------------------------------
$deployList = @()
foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    $art  = $inv.artifacts."vcf_$vKey"
    if (-not $art -or -not $art.esxi_iso_datastore) {
        Write-Warning "skip $v : artifacts.vcf_$vKey.esxi_iso_datastore 沒設定"
        continue
    }
    $sz = $inv.vcf.versions[$v].sizing
    $vcpu = if ($sz -and $sz.vcpu)      { [int]$sz.vcpu }      else { 12 }
    $mem  = if ($sz -and $sz.memory_gb) { [int]$sz.memory_gb } else { 96 }
    foreach ($h in $inv.hosts_by_version[$v]) {
        $deployList += [pscustomobject]@{
            Version   = $v
            VKey      = $vKey
            VMName    = $h.nested_vm_name
            IsoDs     = $art.esxi_iso_datastore
            VCpu      = $vcpu
            MemGB     = $mem
            BootDiskGB     = 10
            CacheDiskGB    = 100
            CapacityDiskGB = 700
        }
    }
}

Write-Host ""
Write-Host "Deploy plan ($($deployList.Count) VMs, fresh-build, sequential):" -ForegroundColor Yellow
$deployList | Format-Table Version, VMName, VCpu, MemGB, BootDiskGB, CacheDiskGB, CapacityDiskGB -AutoSize

# ---- 建 VM helper (New-VM cmdlet + ReconfigVM 補設備) --------------------
function New-NestedEsxiVM {
    param(
        [PSCustomObject] $Item,
        [object] $ParentRP,
        [object] $TargetVapp,
        [object] $Datastore,
        [object] $Portgroup,
        [object] $VMHost
    )

    $vmName = $Item.VMName
    $vmTag  = "$($Item.Version)/$vmName"

    function Write-Step($msg, $color='White') {
        $ts = (Get-Date).ToString('HH:mm:ss')
        Write-Host "[$ts][$vmTag] $msg" -ForegroundColor $color
    }

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Step "VM exists, skip" 'DarkYellow'
        return
    }

    # ---- 1. New-VM: 基本 VM 建到 parent RP 'Kosten' (7.0 vC 不能直接 build 到 vApp) ----
    Write-Step "New-VM in RP '$($ParentRP.Name)' (vmkernel7Guest, vmx-19, $($Item.VCpu) vCPU / $($Item.MemGB) GB)..."
    $vm = New-VM -Name $vmName -ResourcePool $ParentRP -Datastore $Datastore -VMHost $VMHost `
                 -GuestId 'vmkernel7Guest' -HardwareVersion 'vmx-19' `
                 -NumCpu $Item.VCpu -MemoryGB $Item.MemGB `
                 -DiskGB $Item.BootDiskGB -DiskStorageFormat Thin `
                 -Portgroup $Portgroup -CD -Confirm:$false -ErrorAction Stop

    # ---- 2. Set SCSI controller -> PVSCSI ---------------------------------
    $scsi = Get-ScsiController -VM $vm
    Set-ScsiController -SCSIController $scsi -Type ParaVirtual -Confirm:$false | Out-Null

    # ---- 3. Set first NIC -> Vmxnet3 (and add second) ---------------------
    $nic1 = Get-NetworkAdapter -VM $vm | Select-Object -First 1
    Set-NetworkAdapter -NetworkAdapter $nic1 -Type Vmxnet3 -Confirm:$false | Out-Null
    New-NetworkAdapter -VM $vm -Portgroup $Portgroup -Type Vmxnet3 -StartConnected:$true -Confirm:$false | Out-Null

    # ---- 4. Mount ISO to existing CDROM (-CD parameter created it on IDE 0) ----
    $cd = $vm | Get-CDDrive
    Set-CDDrive -CD $cd -IsoPath $Item.IsoDs -StartConnected:$true -Confirm:$false | Out-Null

    # ---- 5. ReconfigVM: add NVMe controller + 2 NVMe disks; firmware EFI;
    #        BootOptions (CDROM first, then SCSI disk1); ExtraConfig phys_bits_used
    $newCfg = $vm.ExtensionData.Config.Hardware.Device
    $disk1Key = ($newCfg | Where-Object { $_.GetType().Name -eq 'VirtualDisk' -and $_.DeviceInfo.Label -eq 'Hard disk 1' }).Key

    $nvmeCtrl = New-Object VMware.Vim.VirtualNVMEController -Property @{
        Key = -2; BusNumber = 0
    }
    $cacheDisk = New-Object VMware.Vim.VirtualDisk -Property @{
        Key = -11; ControllerKey = -2; UnitNumber = 0
        CapacityInKB = [int64]$Item.CacheDiskGB * 1024 * 1024
        Backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo -Property @{
            FileName = ''; DiskMode = 'persistent'; ThinProvisioned = $true
        }
    }
    $capacityDisk = New-Object VMware.Vim.VirtualDisk -Property @{
        Key = -12; ControllerKey = -2; UnitNumber = 1
        CapacityInKB = [int64]$Item.CapacityDiskGB * 1024 * 1024
        Backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo -Property @{
            FileName = ''; DiskMode = 'persistent'; ThinProvisioned = $true
        }
    }

    $bootOpts = New-Object VMware.Vim.VirtualMachineBootOptions -Property @{
        BootOrder = @(
            (New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice),
            (New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice -Property @{ DeviceKey = $disk1Key })
        )
        EfiSecureBootEnabled = $false
        BootRetryEnabled     = $true
        BootRetryDelay       = 10000
    }

    $reconf = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{
        Firmware    = 'efi'
        BootOptions = $bootOpts
        DeviceChange = @(
            (New-Object VMware.Vim.VirtualDeviceConfigSpec -Property @{ Operation='add'; Device=$nvmeCtrl }),
            (New-Object VMware.Vim.VirtualDeviceConfigSpec -Property @{ Operation='add'; Device=$cacheDisk;    FileOperation='create' }),
            (New-Object VMware.Vim.VirtualDeviceConfigSpec -Property @{ Operation='add'; Device=$capacityDisk; FileOperation='create' })
        )
        ExtraConfig = @(
            (New-Object VMware.Vim.OptionValue -Property @{ Key='monitor.phys_bits_used'; Value='45' })
        )
    }
    $task = $vm.ExtensionData.ReconfigVM_Task($reconf)
    $tv = Get-View $task
    while ($tv.Info.State -in 'running','queued') { Start-Sleep 1; $tv.UpdateViewData('Info.State','Info.Error') }
    if ($tv.Info.State -ne 'success') { throw "ReconfigVM failed: $($tv.Info.Error.LocalizedMessage)" }
    Write-Step "  Reconfig: +NVMe ctrl, +cache $($Item.CacheDiskGB)GB, +capacity $($Item.CapacityDiskGB)GB, firmware=EFI, phys_bits=45"

    # ---- 6. Move VM into target vApp (用 API; PowerCLI Move-VM 走 vMotion
    #         語意, 對 vApp 跨 RP 會觸發 DRS placement 找不到 host 而 fail) ----
    Write-Step "moving VM into vApp '$($TargetVapp.Name)'..."
    $TargetVapp.ExtensionData.MoveIntoResourcePool(@($vm.ExtensionData.MoRef))

    Write-Step "powering on..."
    (Get-VM -Id $vm.Id) | Start-VM -Confirm:$false | Out-Null
    Write-Step "✓ done" 'Green'
}

# ---- Sequential deploy ----------------------------------------------------
Write-Host ""
Write-Host "Starting per-version sequential deploy..." -ForegroundColor Cyan
foreach ($group in ($deployList | Group-Object Version)) {
    $version = $group.Name
    $items   = $group.Group
    $vKey    = $version -replace '\.',''
    $vappName = "rtolab-vcf$vKey"

    $deployVapp = Get-VApp -Name $vappName -ErrorAction SilentlyContinue
    if (-not $deployVapp) {
        Write-Host "[$version] creating vApp '$vappName' under RP '$($rp.Name)'..." -ForegroundColor Cyan
        $deployVapp = New-VApp -Name $vappName -Location $rp
    }

    foreach ($item in $items) {
        $vmhost = $availableHosts | Get-Random
        try {
            New-NestedEsxiVM -Item $item -ParentRP $rp -TargetVapp $deployVapp `
                             -Datastore $ds -Portgroup $pg -VMHost $vmhost
        } catch {
            Write-Host "[$version/$($item.VMName)] FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Disconnect-VIServer * -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
Write-Host ""
Write-Host "All deploys done. VMs are at the ESXi installer (UEFI boots BOOTX64.EFI from ISO)." -ForegroundColor Green

# ---- Optionally: generate bringup JSON files ------------------------------
if ($GenerateBringupSpec) {
    foreach ($v in $Versions) {
        $vKey = $v -replace '\.',''
        $vGen = Join-Path $repoRoot "layer2-bringup/vcf$vKey/Generate-BringupSpec.ps1"
        $vOut = Join-Path $repoRoot "layer2-bringup/vcf$vKey/generated-bringup.json"
        if (-not (Test-Path $vGen)) { continue }
        Write-Host ""
        Write-Host "Generating bringup spec for $v -> $vOut ..." -ForegroundColor Cyan
        & $vGen -LabMode -OutputFile $vOut
    }
}

Write-Host ""
Write-Host "下一步: 在每台 VM console 上手動跑 ESXi installer (或之後加 kickstart 自動化)" -ForegroundColor Cyan
Write-Host "  裝完 + 確認可 ssh: 跑 pwsh scripts\ConvertTo-NestedTemplate.ps1 凍 template"
