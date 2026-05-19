<#
.SYNOPSIS
    對 nested ESXi 做 bringup-ready cleanup:
    1. 卸 / 摧毀殘存 vSAN partition (前次 bringup 失敗留下的)
    2. 把 100GB cache disk 標成 SSD (nested 預設 HDD, vSAN ESA 需要 SSD)
    3. 移除殘存 standard vSwitch (不是 vSwitch0)
    4. 移除殘存 vmk30 (NSX TEP, 前次 bringup 留下)
    5. /sbin/auto-backup.sh 持久化
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string[]] $EsxiHosts
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')
Import-Module Posh-SSH
Import-Module powershell-yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
$pw = ConvertTo-SecureString $secrets.esxi.root_pw -AsPlainText -Force
$cred = New-Object PSCredential 'root', $pw

foreach ($ip in $EsxiHosts) {
    Write-Host ""
    Write-Host "=== $ip ===" -ForegroundColor Cyan
    $s = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -ConnectionTimeout 15 -ErrorAction SilentlyContinue
    if (-not $s) { Write-Warning "  SSH fail (re-enable SSH via vCenter UI / GuestOps first)"; continue }

    # 1. Clean vSAN partition / cluster membership
    Write-Host "  [1/5] vSAN cleanup..."
    Invoke-SSHCommand -SessionId $s.SessionId -Command 'esxcli vsan cluster leave 2>/dev/null; esxcli vsan storage remove --uuid=$(esxcli vsan storage list | grep "VSAN UUID" | head -1 | awk "{print \$3}") 2>/dev/null' -TimeOut 60 | Out-Null
    # Wipe partitions on non-boot disks (NVMe 100GB + 700GB)
    Invoke-SSHCommand -SessionId $s.SessionId -Command 'for d in $(esxcli storage core device list 2>/dev/null | awk "/^t10\.|^naa\./ {print \$1}"); do
        # Skip boot device
        bootdev=$(esxcli storage core device list | awk "/Is Boot Device: true/{getline; print}" | head -1)
        if [ "$d" = "$bootdev" ]; then continue; fi
        partedUtil delete /vmfs/devices/disks/$d 1 2>/dev/null
        partedUtil delete /vmfs/devices/disks/$d 2 2>/dev/null
        partedUtil delete /vmfs/devices/disks/$d 3 2>/dev/null
    done' -TimeOut 60 | Out-Null

    # 2. Mark 100GB NVMe as SSD (and 700GB as capacity)
    Write-Host "  [2/5] Mark non-boot NVMe as SSD..."
    $r = Invoke-SSHCommand -SessionId $s.SessionId -Command 'esxcli storage core device list 2>/dev/null | grep -E "^t10\.|^naa\." | grep -v "(boot)" | head -3' -TimeOut 30
    $devs = $r.Output | Where-Object { $_ -match '^(t10\.|naa\.)' }
    foreach ($d in $devs) {
        $devid = $d.Trim()
        Invoke-SSHCommand -SessionId $s.SessionId -Command "esxcli storage nmp satp rule add --satp=VMW_SATP_LOCAL --device='$devid' --option='enable_ssd' 2>&1" -TimeOut 30 | Out-Null
        Invoke-SSHCommand -SessionId $s.SessionId -Command "esxcli storage core claiming reclaim --device='$devid' 2>&1" -TimeOut 30 | Out-Null
    }

    # 3. Remove non-vSwitch0 standard vSwitches
    Write-Host "  [3/5] Removing leftover vSwitches..."
    Invoke-SSHCommand -SessionId $s.SessionId -Command 'for sw in $(esxcli network vswitch standard list | awk "/^[a-zA-Z]/ && /witch/ && !/Name|Configured/ {print \$1}" | grep -v "^vSwitch0$"); do esxcli network vswitch standard remove --vswitch-name="$sw" 2>&1; done' -TimeOut 30 | Out-Null

    # 4. Remove vmk30
    Write-Host "  [4/5] Removing vmk30..."
    Invoke-SSHCommand -SessionId $s.SessionId -Command 'esxcli network ip interface remove --interface-name=vmk30 2>&1; esxcli network ip interface remove --interface-name=vmk1 2>&1; esxcli network ip interface remove --interface-name=vmk2 2>&1' -TimeOut 30 | Out-Null

    # 5. Final state + persist
    Write-Host "  [5/5] Verify + persist..."
    $r2 = Invoke-SSHCommand -SessionId $s.SessionId -Command 'esxcli storage core device list | grep -E "Is SSD|Display Name" | head -10; echo ===; esxcli network vswitch standard list | grep ^vSwitch; esxcli network ip interface list | grep ^vmk; /sbin/auto-backup.sh > /dev/null 2>&1 && echo backup-ok' -TimeOut 60
    $r2.Output | Select-Object -First 12 | ForEach-Object { Write-Host "    $_" }
    Remove-SSHSession -SessionId $s.SessionId | Out-Null
}
Write-Host ""
Write-Host "完成. Re-submit bringup." -ForegroundColor Cyan
