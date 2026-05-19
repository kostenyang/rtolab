<#
.SYNOPSIS
    SCP the ESXi 8.0U3b depot zip into each 5.2.1 nested ESXi and run
    `esxcli software profile update` against local path, then reboot.
    Build 24022510 → 24280767, matches CB 5.2.1 GA requirement.
#>
[CmdletBinding()]
param(
    [string[]] $Hosts = @('192.168.114.50','192.168.114.51','192.168.114.52','192.168.114.53'),
    [string]   $DepotZip = 'E:\5.2.1\VMware-ESXi-8.0U3b-24280767-depot.zip'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable Posh-SSH)) { Install-Module Posh-SSH -Scope CurrentUser -Force | Out-Null }
Import-Module Posh-SSH
Import-Module powershell-yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
$pw = ConvertTo-SecureString $secrets.esxi.root_pw -AsPlainText -Force
$cred = New-Object PSCredential 'root', $pw

if (-not (Test-Path $DepotZip)) { throw "Depot zip 不存在: $DepotZip" }
$zipName = Split-Path $DepotZip -Leaf
$remotePath = "/vmfs/volumes/OSDATA-6a0b1c75-2f3d7fdc-008e-005056a5b4d1/$zipName"

foreach ($ip in $Hosts) {
    Write-Host ""
    Write-Host "=== $ip ===" -ForegroundColor Cyan
    $s = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -ConnectionTimeout 15
    try {
        # Ensure SSH enabled (re-enable if not — vim-cmd persists across reboots if auto-backup'd)
        Invoke-SSHCommand -SessionId $s.SessionId -Command 'vim-cmd hostsvc/enable_ssh; vim-cmd hostsvc/start_ssh' | Out-Null

        # Check if already at target build
        $cur = (Invoke-SSHCommand -SessionId $s.SessionId -Command 'esxcli system version get | grep Build').Output -join ''
        Write-Host "  current: $cur"
        if ($cur -match '24280767') {
            Write-Host "  ✓ already at target build, skip" -ForegroundColor Green
            continue
        }

        # Get OSDATA mount path (uuid may differ per host)
        $osdata = (Invoke-SSHCommand -SessionId $s.SessionId -Command 'ls -d /vmfs/volumes/OSDATA-* | head -1').Output -join '' -replace "`n",''
        $hostRemotePath = "$osdata/$zipName"
        Write-Host "  remote path: $hostRemotePath"

        # SCP depot zip (use SFTP)
        $sftp = New-SFTPSession -ComputerName $ip -Credential $cred -AcceptKey -ConnectionTimeout 30
        try {
            $exists = Get-SFTPChildItem -SessionId $sftp.SessionId -Path $osdata -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $zipName }
            $expectedSize = (Get-Item $DepotZip).Length
            if ($exists -and $exists.Length -eq $expectedSize) {
                Write-Host "  zip already present and size matches, skip upload"
            } else {
                Write-Host "  uploading $([math]::Round($expectedSize/1MB,0))MB depot zip..."
                Set-SFTPItem -SessionId $sftp.SessionId -Path $DepotZip -Destination $osdata -Force
                Write-Host "  upload complete"
            }
        } finally {
            Remove-SFTPSession -SessionId $sftp.SessionId | Out-Null
        }

        # List profiles available in this depot
        Write-Host "  listing profiles..."
        $r = Invoke-SSHCommand -SessionId $s.SessionId -Command "esxcli software sources profile list -d '$hostRemotePath' 2>&1" -TimeOut 120
        $r.Output | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }
        $profile = ($r.Output | Where-Object { $_ -match 'ESXi-8\.0U3b-24280767-standard' } | Select-Object -First 1) -replace ' .*',''
        if (-not $profile) {
            $profile = ($r.Output | Where-Object { $_ -match 'standard$|^ESXi-' } | Select-Object -First 1) -replace ' .*',''
        }
        if (-not $profile) { Write-Warning "  couldn't find profile name, skip"; continue }
        Write-Host "  profile: $profile"

        Write-Host "  esxcli software profile update (~5min)..."
        $r2 = Invoke-SSHCommand -SessionId $s.SessionId -Command "esxcli software profile update -d '$hostRemotePath' -p $profile --no-hardware-warning 2>&1 | tail -20" -TimeOut 900
        $r2.Output | ForEach-Object { Write-Host "    $_" }

        Write-Host "  Rebooting..."
        Invoke-SSHCommand -SessionId $s.SessionId -Command 'reboot' -TimeOut 5 -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-SSHSession -SessionId $s.SessionId | Out-Null
    }
}

Write-Host ""
Write-Host "完成. 等 ~3-5 min 給每台 reboot, 然後驗 build:"
Write-Host "  pwsh -c \"foreach (\\$ip in @('.50','.51','.52','.53')) { ssh root@192.168.114\\$ip 'esxcli system version get' }\""
