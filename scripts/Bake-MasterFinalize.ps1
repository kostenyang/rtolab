<#
.SYNOPSIS
    SSH 進 master, 加 /Net/FollowHardwareMac=1 (clone 第一次 boot 會自動把 vmk0 bind
    到 new vNIC MAC), 然後 /sbin/auto-backup.sh 寫進 boot bank.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $EsxiHost
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable Posh-SSH)) { Install-Module Posh-SSH -Scope CurrentUser -Force | Out-Null }
Import-Module Posh-SSH
Import-Module powershell-yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

$securePw = ConvertTo-SecureString $secrets.esxi.root_pw -AsPlainText -Force
$cred = New-Object PSCredential 'root', $securePw

Write-Host "SSH root@$EsxiHost ..." -ForegroundColor Cyan
$s = New-SSHSession -ComputerName $EsxiHost -Credential $cred -AcceptKey -ConnectionTimeout 30
try {
    $cmds = @(
        'esxcli system settings advanced set -o /Net/FollowHardwareMac -i 1',
        'esxcli system settings advanced list -o /Net/FollowHardwareMac | grep -E "Path|Int Value"',
        '/sbin/auto-backup.sh'
    )
    foreach ($c in $cmds) {
        Write-Host "  $ $c"
        $r = Invoke-SSHCommand -SessionId $s.SessionId -Command $c
        if ($r.Output) { $r.Output | ForEach-Object { Write-Host "    $_" } }
        if ($r.ExitStatus -ne 0) { Write-Warning "    exit=$($r.ExitStatus)" }
    }
    Write-Host "✓ $EsxiHost finalized (FollowHardwareMac=1 + auto-backup persisted)" -ForegroundColor Green
} finally {
    Remove-SSHSession -SessionId $s.SessionId | Out-Null
}
