#Requires -Version 7.0
<#
.SYNOPSIS
    CI dry-run: Layer 1 vSAN settings check + Layer 2 bringup spec generation.
    Exits 0 only if both pass.
#>
param(
    [string] $EsxiPassword    = $env:ESXI_ROOT_PW,
    [string] $EsxiPasswordPso = $env:ESXI_ROOT_PW_PSO,
    [string] $RepoRoot        = $env:GITHUB_WORKSPACE
)

# Note: Set-StrictMode intentionally NOT set here — it propagates to child
# scripts (Prepare-NestedESXi-auto.ps1) that use $global:DefaultVIServers
# before PowerCLI initialises it, which causes false failures.
$ErrorActionPreference = 'Stop'

$failed = $false

# ── helpers ──────────────────────────────────────────────────────────────────
function Write-Section ([string]$title) {
    Write-Output ""
    Write-Output "=" * 60
    Write-Output "  $title"
    Write-Output "=" * 60
}

function Write-Fail ([string]$msg) {
    Write-Output "::error::$msg"
    $script:failed = $true
}

# ── Layer 1: vSAN/LSOM dry-run ───────────────────────────────────────────────
Write-Section "Layer 1 — Prepare-NestedESXi dry-run"

$defaultHosts = @('192.168.114.14','192.168.114.15','192.168.114.16','192.168.114.17')

if (-not $EsxiPassword -and -not $EsxiPasswordPso) {
    Write-Output "::warning::Neither ESXI_ROOT_PW nor ESXI_ROOT_PW_PSO is set — skipping Layer 1 dry-run."
} else {
    try {
        Import-Module VMware.VimAutomation.Core -DisableNameChecking -ErrorAction Stop
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false `
            -DefaultVIServerMode Single -Confirm:$false -Scope Session | Out-Null

        # Build ordered credential map for whichever secrets are present
        $creds = [ordered]@{}
        if ($EsxiPassword)    { $creds['primary'] = [PSCredential]::new('root', (ConvertTo-SecureString $EsxiPassword    -AsPlainText -Force)) }
        if ($EsxiPasswordPso) { $creds['pso']     = [PSCredential]::new('root', (ConvertTo-SecureString $EsxiPasswordPso -AsPlainText -Force)) }

        # Probe each host — assign to first credential that connects successfully
        $groups = @{}
        foreach ($h in $defaultHosts) {
            $matched = $false
            foreach ($credKey in $creds.Keys) {
                try {
                    $vi = Connect-VIServer -Server $h -Credential $creds[$credKey] -Force -ErrorAction Stop
                    Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    if (-not $groups[$credKey]) { $groups[$credKey] = [System.Collections.Generic.List[string]]::new() }
                    $groups[$credKey].Add($h)
                    Write-Output "  $h  ->  $credKey"
                    $matched = $true
                    break
                } catch {
                    # try next credential
                }
            }
            if (-not $matched) {
                Write-Fail "Could not connect to $h with any credential."
            }
        }

        # Run dry-run once per credential group
        $l1script = Join-Path $RepoRoot "layer1-nested\Prepare-NestedESXi-auto.ps1"
        foreach ($credKey in $groups.Keys) {
            $hostList = $groups[$credKey].ToArray()
            Write-Output ""
            Write-Output "Running dry-run [$credKey] on: $($hostList -join ', ')"
            $global:LAB_CRED = $creds[$credKey]
            & $l1script -Hosts $hostList -DryRun
        }

        if (-not $script:failed) {
            Write-Output ""
            Write-Output "Layer 1 dry-run: PASS"
        }
    } catch {
        Write-Fail "Layer 1 dry-run failed: $_"
    }
}

# ── Layer 2: bringup spec generation ─────────────────────────────────────────
Write-Section "Layer 2 — Generate-BringupSpec validation (VCF 9.1)"

$specScript  = Join-Path $RepoRoot "layer2-bringup\vcf91\Generate-BringupSpec.ps1"
$secretsFile = Join-Path $RepoRoot "inventory\secrets\lab.yaml"
$ageKeyFile  = Join-Path $env:USERPROFILE ".config\sops\age\keys.txt"

if (-not (Test-Path $secretsFile)) {
    Write-Output "::warning::inventory/secrets/lab.yaml not found — skipping Layer 2 (run locally where sops secrets exist)."
} elseif (-not (Test-Path $ageKeyFile)) {
    Write-Output "::warning::sops age key not found at $ageKeyFile — skipping Layer 2 spec generation."
} elseif (-not (Test-Path $specScript)) {
    Write-Fail "Spec script not found: $specScript"
} else {
    try {
        $outDir    = Join-Path $env:RUNNER_TEMP "dryrun-specs"
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $outputFile = Join-Path $outDir "generated-bringup.json"

        Write-Output "Running: $specScript -LabMode -OutputFile $outputFile"
        & $specScript -LabMode -OutputFile $outputFile 2>&1

        # Validate every JSON file produced
        $jsons = Get-ChildItem $outDir -Filter "*.json" -ErrorAction SilentlyContinue
        if ($jsons.Count -eq 0) {
            Write-Fail "No JSON spec files produced by Generate-BringupSpec.ps1"
        } else {
            $jsonErrors = @()
            foreach ($j in $jsons) {
                try {
                    $null = Get-Content $j.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    Write-Output "  JSON OK : $($j.Name)"
                } catch {
                    $jsonErrors += "$($j.Name): $_"
                }
            }
            if ($jsonErrors) {
                $jsonErrors | ForEach-Object { Write-Fail "JSON invalid: $_" }
            } else {
                Write-Output ""
                Write-Output "Layer 2 spec generation: PASS ($($jsons.Count) file(s))"
            }
        }
    } catch {
        Write-Fail "Layer 2 spec generation failed: $_"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Section "Summary"
if ($failed) {
    Write-Output "::error::Dry-run FAILED — see errors above."
    exit 1
}
Write-Output "All dry-run checks PASSED."
exit 0
