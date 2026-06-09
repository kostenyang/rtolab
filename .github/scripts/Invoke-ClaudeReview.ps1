#Requires -Version 7.0
<#
.SYNOPSIS
    Calls Claude API to review a PR diff and posts/updates a comment.

.PARAMETER PrNumber
    GitHub PR number to review.

.PARAMETER Repo
    GitHub repo in owner/name format (e.g. kostenyang/rtolab).

.PARAMETER AnthropicKey
    Anthropic API key. Reads $env:ANTHROPIC_API_KEY if not supplied.

.PARAMETER GhToken
    GitHub token with pull-requests:write. Reads $env:GH_TOKEN if not supplied.
#>
param(
    [Parameter(Mandatory)] [string] $PrNumber,
    [Parameter(Mandatory)] [string] $Repo,
    [string] $AnthropicKey = $env:ANTHROPIC_API_KEY,
    [string] $GhToken      = $env:GH_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $AnthropicKey) { throw "ANTHROPIC_API_KEY is not set." }
if (-not $GhToken)      { throw "GH_TOKEN is not set." }

$GhHeaders = @{
    Authorization = "Bearer $GhToken"
    Accept        = "application/vnd.github+json"
}

# ── 1. Fetch PR metadata ────────────────────────────────────────────────────
Write-Output "Fetching PR #$PrNumber metadata..."
$pr = Invoke-RestMethod "https://api.github.com/repos/$Repo/pulls/$PrNumber" -Headers $GhHeaders

$prTitle  = $pr.title
$prBody   = $pr.body ?? "(no description)"
$baseSha  = $pr.base.sha
$headSha  = $pr.head.sha

# ── 2. Fetch changed files list ─────────────────────────────────────────────
$filesResp = Invoke-RestMethod "https://api.github.com/repos/$Repo/pulls/$PrNumber/files" -Headers $GhHeaders
$fileList  = ($filesResp | ForEach-Object { "  $($_.status.PadRight(8)) $($_.filename)" }) -join "`n"

# ── 3. Fetch diff ────────────────────────────────────────────────────────────
Write-Output "Fetching diff..."
$diffHeaders = $GhHeaders + @{ Accept = "application/vnd.github.v3.diff" }
$rawDiff     = Invoke-RestMethod "https://api.github.com/repos/$Repo/pulls/$PrNumber" -Headers $diffHeaders

# Keep only .ps1 / .yaml / .yml / .md hunks; truncate at 18k chars
$relevantExt = '\.ps1|\.yaml|\.yml|\.md|\.psd1'
$diffLines   = $rawDiff -split "`n"
$kept        = [System.Text.StringBuilder]::new()
$inRelevant  = $false

foreach ($line in $diffLines) {
    if ($line -match '^diff --git') {
        $inRelevant = $line -match $relevantExt
    }
    if ($inRelevant) { [void]$kept.AppendLine($line) }
    if ($kept.Length -gt 18000) {
        [void]$kept.AppendLine("`n[... diff truncated at 18k chars ...]")
        break
    }
}

$diff = if ($kept.Length -gt 0) { $kept.ToString() } else { "(no relevant diff)" }

# ── 4. Build Claude request ──────────────────────────────────────────────────
$systemPrompt = @'
You are an expert PowerShell and VMware/VCF infrastructure code reviewer.

You are reviewing changes to `rtolab` — a lab automation repo that manages three simultaneous VCF environments (9.1, 9.0, 5.2.1) using nested ESXi on a shared physical cluster (SELAB-Cluster, outer vCenter 172.16.10.100).

Key conventions:
- Scripts run on Windows Server 2022 (172.16.10.32), pwsh 7 only — never powershell.exe
- Secrets come from sops+age encrypted inventory/secrets/lab.yaml — hardcoded credentials are a blocker
- ConvertTo-SecureString -AsPlainText -Force is the accepted lab pattern for PowerCLI credentials
- Pass -Hosts arrays with: pwsh -Command "& 'script.ps1' -Hosts a,b,c,d" (not pwsh -File — it mangles arrays)
- After ESXi clone: must run Fix-CloneNetwork → Apply-CloneIp → Regen-EsxiCert in that order
- vmk0 IP: set IP+mask first, then gateway separately (chicken-and-egg with ipv4 set -g)
- vmx-19 required for nested ESXi — vmx-14 causes PSOD at 0.73s
- VCF 9.1 full Option B bringup: must run _add_auto_ops_spec.ps1 (base spec alone is incomplete)
- All workaround/setting scripts must be idempotent — already-correct state skipped silently
- Batch scripts emit *-yyyyMMdd-HHmmss.csv logs in working dir
- vSAN/LSOM advanced settings: 6 keys, must match layer1-nested exactly when re-applied in layer4-day2

Review criteria (check all that apply to the diff):
1. **Correctness** — would this script work correctly against the lab?
2. **Security** — secrets handled properly? No hardcoded credentials or tokens?
3. **Idempotency** — safe to re-run without side effects?
4. **Error handling** — failures caught, reported, and script exits non-zero on failure?
5. **Lab conventions** — follows the patterns listed above?

Format as GitHub-flavored Markdown:
- Start with a one-sentence summary
- Use ⛔ for blocking issues (must fix before merge)
- Use ⚠️ for important suggestions
- Use ✅ for things done well
- Max ~500 words. Be specific — reference file names and line numbers where possible.
'@

$userMessage = @"
**PR #${PrNumber}: ${prTitle}**

**Description:**
${prBody}

**Changed files:**
${fileList}

**Diff (ps1/yaml/yml/md only):**
``````diff
${diff}
``````
"@

$requestBody = @{
    model      = "claude-sonnet-4-6"
    max_tokens = 1500
    system     = @(
        @{
            type          = "text"
            text          = $systemPrompt
            cache_control = @{ type = "ephemeral" }
        }
    )
    messages   = @(
        @{
            role    = "user"
            content = $userMessage
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

# ── 5. Call Claude API ───────────────────────────────────────────────────────
Write-Output "Calling Claude API (claude-sonnet-4-6)..."
$apiHeaders = @{
    "x-api-key"         = $AnthropicKey
    "anthropic-version" = "2023-06-01"
    "anthropic-beta"    = "prompt-caching-2024-07-31"
    "content-type"      = "application/json"
}

$apiResponse = Invoke-RestMethod `
    -Uri    "https://api.anthropic.com/v1/messages" `
    -Method POST `
    -Headers $apiHeaders `
    -Body   $requestBody

$reviewText   = $apiResponse.content[0].text
$inputTokens  = $apiResponse.usage.input_tokens
$outputTokens = $apiResponse.usage.output_tokens
$cacheRead    = $apiResponse.usage.cache_read_input_tokens ?? 0

Write-Output "Tokens: input=$inputTokens output=$outputTokens cache_hit=$cacheRead"

# ── 6. Post / update PR comment ──────────────────────────────────────────────
$MARKER      = "<!-- claude-ai-review -->"
$commentsUrl = "https://api.github.com/repos/$Repo/issues/$PrNumber/comments"

$existingComments = Invoke-RestMethod -Uri $commentsUrl -Headers $GhHeaders
$existing = $existingComments | Where-Object { $_.body -like "*$MARKER*" } | Select-Object -First 1

$sha7        = $headSha.Substring(0, 7)
$commentBody = @"
$MARKER
## 🤖 Claude Code Review

$reviewText

---
*claude-sonnet-4-6 · commit ${sha7} · tokens in=${inputTokens} out=${outputTokens} cache=${cacheRead}*
"@

if ($existing) {
    Write-Output "Updating existing review comment $($existing.id)..."
    Invoke-RestMethod -Uri $existing.url -Method PATCH -Headers $GhHeaders `
        -Body (@{ body = $commentBody } | ConvertTo-Json) | Out-Null
    Write-Output "Comment updated: $($existing.html_url)"
} else {
    Write-Output "Posting new review comment..."
    $newComment = Invoke-RestMethod -Uri $commentsUrl -Method POST -Headers $GhHeaders `
        -Body (@{ body = $commentBody } | ConvertTo-Json)
    Write-Output "Comment posted: $($newComment.html_url)"
}
