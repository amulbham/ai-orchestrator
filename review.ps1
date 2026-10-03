param(
  [Parameter(Mandatory)][string]$Id,
  [Parameter(Mandatory)][string]$TicketPath,   # repo-relative, inside the worktree
  [Parameter(Mandatory)][string]$Worktree,     # relative to this folder, or absolute
  [ValidateSet('R1','R2','R3')][string]$Tier = 'R1',  # R1/R2 = Codex; R3 = Codex + Grok
  [switch]$Elevate,                            # run both reviewers for a lower tier; marks the summary ELEVATED
  [string]$PromptPath = '',                    # override prompt file; recorded in the header
  [string]$OutDir = 'reviews',                 # review files, manifest and summary go here
  [string[]]$Extra = @()                       # extra files (worktree-relative or absolute) for the reviewer / stdin bundle
)
$ErrorActionPreference = 'Stop'

# ---- Bindings: every invocation passes these explicitly; no CLI default is relied on ----
$CodexModel         = 'gpt-6.1-sol'
$CodexEffort        = 'medium'
$CodexFallbackModel = 'gpt-5.6-sol'
$GrokModel          = 'grok-4.7'
$GrokEffort         = 'high'
$GrokMaxTurns       = 12
$CodexTimeoutSec    = 1800
$GrokTimeoutSec     = 900
# ------------------------------------------------------------------------------------------

$o = $PSScriptRoot
function Abs($p, $base) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $base $p } }
$wt = (Resolve-Path (Abs $Worktree $o)).Path
$out = Abs $OutDir $o
New-Item -ItemType Directory -Force $out | Out-Null
$out = (Resolve-Path $out).Path
$rawDir = Join-Path $o 'scratch\raw'; New-Item -ItemType Directory -Force $rawDir | Out-Null
$log = Join-Path $o 'scratch\run-log.md'
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$utf8 = New-Object Text.UTF8Encoding $false
$commit = (git -C $wt rev-parse HEAD).Trim()
$runId = [guid]::NewGuid().ToString()
$reviewers = @('codex'); if ($Tier -eq 'R3' -or $Elevate) { $reviewers += 'grok' }

function Q($s) { if ($s -eq '') { return '""' }; if ($s -notmatch '[\s"]') { return $s }; '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
function Cmd($name) { (Get-Command $name -ErrorAction Stop | Select-Object -First 1).Source }

# Run an exe with optional stdin text; returns Exit, Out, Err, Secs, TimedOut. No shell involved.
function RunProc($exe, $argList, $stdinText, $timeoutSec) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $exe; $psi.Arguments = (($argList | ForEach-Object { Q $_ }) -join ' ')
  $psi.WorkingDirectory = $wt; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  $t = Get-Date
  $p = [Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $bytes = $utf8.GetBytes([string]$stdinText)
  try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush() } catch {}
  try { $p.StandardInput.Close() } catch {}
  $timedOut = $false
  if (-not $p.WaitForExit($timeoutSec * 1000)) { $timedOut = $true; & taskkill /T /F /PID $p.Id | Out-Null }
  $p.WaitForExit()
  [pscustomobject]@{ Exit = $p.ExitCode; Out = $so.Result; Err = $se.Result; Secs = [int]((Get-Date) - $t).TotalSeconds; TimedOut = $timedOut }
}

function HasVerdict($t) { [bool]($t -and ($t -match '(?m)^\s*VERDICT:')) }

# ---- Prompt (line structure preserved; delivered by stdin or arg, never flattened) ----
$promptFile = $null; $promptSource = 'worktree template'
if ($PromptPath) { $promptFile = (Resolve-Path (Abs $PromptPath (Get-Location).Path)).Path; $promptSource = "OVERRIDE -PromptPath $promptFile" }
else { $promptFile = Join-Path $wt 'site\planning\templates\pre-seal-review.md'; if (-not (Test-Path $promptFile)) { throw "prompt not found: $promptFile (use -PromptPath)" } }
$m = [regex]::Match([IO.File]::ReadAllText($promptFile), '(?s)```text\s*(.*?)```')
if (-not $m.Success) { throw "no ```text block in $promptFile" }
$extraAbs = @(); foreach ($e in $Extra) { $p = Abs $e $wt; if (-not (Test-Path $p)) { throw "-Extra file not found: $e" }; $extraAbs += (Resolve-Path $p).Path }
$extraNote = if ($extraAbs.Count) { "`nAlso read these files: " + ($Extra -join ', ') + "." } else { '' }
$prompt = ("Draft ticket: $TicketPath (in the current working directory).`n`n" + ($m.Groups[1].Value.Trim() -replace "`r", '') + $extraNote)

# ---- Stdin bundle: ticket + every Inherits source at its pinned commit + Extra files, all line-numbered. Any miss = hard fail ----
function Num($text) { $i = 0; (($text -split "`r?`n") | ForEach-Object { $i++; "${i}: $_" }) -join "`n" }
function BuildBundle {
  $ticketFile = Join-Path $wt $TicketPath
  if (-not (Test-Path $ticketFile)) { throw "bundle: ticket not found $TicketPath" }
  $ticketText = [IO.File]::ReadAllText($ticketFile)
  $parts = @("===== TICKET $TicketPath =====`n" + (Num $ticketText))
  $inh = [regex]::Match($ticketText, '(?m)^Inherits:\s*(.+)$')
  if (-not $inh.Success) { throw 'bundle: ticket has no Inherits: line' }
  foreach ($seg in ($inh.Groups[1].Value -split ';')) {
    $rev = [regex]::Match($seg, '@\s*`?([0-9a-f]{7,40})`?')
    $pth = [regex]::Match($seg, '`([^`\s]+\.[A-Za-z0-9]+)`')
    if (-not $rev.Success -or -not $pth.Success) { throw "bundle: cannot resolve Inherits segment: $seg" }
    $src = $null
    foreach ($cand in @($pth.Groups[1].Value, "site/$($pth.Groups[1].Value)")) {
      $s = git -C $wt show "$($rev.Groups[1].Value):$cand" 2>$null
      if ($LASTEXITCODE -eq 0) { $src = ($s -join "`n"); $label = "$cand @ $($rev.Groups[1].Value)"; break }
    }
    if ($null -eq $src) { throw "bundle: git show failed for $($pth.Groups[1].Value) @ $($rev.Groups[1].Value)" }
    $parts += "===== $label =====`n" + (Num $src)
  }
  foreach ($f in $extraAbs) { $parts += "===== EXTRA $f =====`n" + (Num ([IO.File]::ReadAllText($f))) }
  $parts -join "`n`n"
}

# ---- Codex ----
function RunCodexOnce($model, $stdin) {
  $oFile = Join-Path $rawDir "$Id-codex-$stamp-last.md"
  if (Test-Path $oFile) { Remove-Item $oFile -Force }
  $a = @('exec','-s','read-only','-m',$model,'-c',"model_reasoning_effort=$CodexEffort",'-C',$wt,'--skip-git-repo-check','-o',$oFile,'-')
  $r = RunProc (Cmd 'codex') $a $stdin $CodexTimeoutSec
  $all = $r.Out + "`n" + $r.Err
  Set-Content (Join-Path $rawDir "$Id-codex-$stamp-full.txt") $all -Encoding utf8
  $body = if (Test-Path $oFile) { [IO.File]::ReadAllText($oFile) } else { '' }
  $rm = [regex]::Match($all, '(?m)^model:\s*(\S+)'); $re = [regex]::Match($all, '(?m)^reasoning effort:\s*(\S+)')
  [pscustomobject]@{ Body = $body; All = $all; Exit = $r.Exit; Secs = $r.Secs; TimedOut = $r.TimedOut
    RepModel = $(if ($rm.Success) { $rm.Groups[1].Value } else { 'not-reported' }); RepEffort = $(if ($re.Success) { $re.Groups[1].Value } else { 'not-reported' }) }
}
function ReviewCodex {
  $fallbacks = @(); $model = $CodexModel; $useBundle = $false; $bundle = $null; $total = 0; $r = $null; $attempts = 0
  foreach ($attempt in 1..2) {
    $attempts = $attempt
    if (-not $useBundle) {
      $r = RunCodexOnce $model $prompt; $total += $r.Secs
      if (-not (HasVerdict $r.Body) -and $model -eq $CodexModel -and $r.All -match '(?i)unknown model|invalid model|model.{0,80}(not found|unavailable|does not exist|not exist|not supported)') {
        $fallbacks += "model $CodexModel -> $CodexFallbackModel"; $model = $CodexFallbackModel
        $r = RunCodexOnce $model $prompt; $total += $r.Secs
      }
      if (-not (HasVerdict $r.Body) -or $r.All -match 'setup refresh had errors|helper_unknown_error|Failed to create unified exec') {
        if (-not (HasVerdict $r.Body)) { $useBundle = $true; $fallbacks += 'stdin-bundle (live read-only run unusable)' }
      }
    }
    if ($useBundle) {
      if (-not $bundle) { $bundle = BuildBundle }   # throws (visible failure) if any source is missing
      $r = RunCodexOnce $model ($prompt + "`nShell access is unavailable; the ticket and its sources follow on stdin with line numbers. Cite file:line from them.`n`n" + $bundle); $total += $r.Secs
    }
    if (HasVerdict $r.Body) { break }
  }
  [pscustomobject]@{ Name = 'codex'; Body = $r.Body; Model = $r.RepModel; Effort = $r.RepEffort; Pinned = "model=$CodexModel effort=$CodexEffort"
    Mode = $(if ($useBundle) { 'stdin bundle (no shell)' } else { 'live repo reads' }); Fallbacks = $(if ($fallbacks.Count) { $fallbacks -join '; ' } else { 'none' })
    Secs = $total; Exit = $r.Exit; Attempts = $attempts; Ok = (HasVerdict $r.Body) }
}

# ---- Grok ----
function ReviewGrok {
  $gp = $prompt + "`nBUDGET: hard wall-clock limit of about 3 minutes. At most 8 tool calls (read files in parallel), then STOP and write the final findings and the VERDICT line."
  $a = @('-p',$gp,'-m',$GrokModel,'--effort',$GrokEffort,'--output-format','json','--max-turns',"$GrokMaxTurns",'--permission-mode','dontAsk','--sandbox','read-only','--disable-web-search')
  $total = 0; $body = ''; $rep = 'not-reported'; $stop = ''; $turns = ''; $exit = -1; $att = 0
  foreach ($attempt in 1..2) {
    $att = $attempt
    $r = RunProc (Cmd 'grok') $a '' $GrokTimeoutSec; $total += $r.Secs; $exit = $r.Exit
    Set-Content (Join-Path $rawDir "$Id-grok-$stamp-a$attempt.json") ($r.Out + "`n" + $r.Err) -Encoding utf8
    $body = ''
    try { $j = $r.Out | ConvertFrom-Json; $body = [string]$j.text; $stop = $j.stopReason; $turns = $j.num_turns
          if ($j.modelUsage) { $rep = (($j.modelUsage.PSObject.Properties.Name) -join ',') } } catch { $stop = "unparseable-json timedout=$($r.TimedOut)" }
    if (HasVerdict $body) { break }
  }
  [pscustomobject]@{ Name = 'grok'; Body = $body; Model = $rep; Effort = "not reported by CLI (passed --effort $GrokEffort)"; Pinned = "model=$GrokModel effort=$GrokEffort"
    Mode = "headless json, stop=$stop turns=$turns"; Fallbacks = 'none'; Secs = $total; Exit = $exit; Attempts = $att; Ok = (HasVerdict $body) }
}

# ---- Run, write review files, manifest ----
foreach ($f in @("$Id-manifest.txt", "$Id-summary.md") + ($reviewers | ForEach-Object { "$Id-$_.md" })) { $p = Join-Path $out $f; if (Test-Path $p) { Remove-Item $p -Force } }
$allOk = $true; $manifest = @("RunId: $runId", "Id: $Id", "Tier: $Tier", "Elevate: $([bool]$Elevate)", "Commit: $commit", "Reviewers: $($reviewers -join ',')")
foreach ($rv in $reviewers) {
  $res = if ($rv -eq 'codex') { ReviewCodex } else { ReviewGrok }
  if (-not $res.Ok) { $allOk = $false }
  $hdr = @("RunId: $runId", "Id: $Id", "Reviewer: $($res.Name)", "Pinned: $($res.Pinned)", "ModelReported: $($res.Model)", "EffortReported: $($res.Effort)",
           "Commit: $commit", "Prompt: $promptSource", "Mode: $($res.Mode)", "Fallbacks: $($res.Fallbacks)", "Attempts: $($res.Attempts)",
           "DurationSecs: $($res.Secs)", "ExitCode: $($res.Exit)", "Status: $(if ($res.Ok) { 'OK' } else { 'FAILED' })", '=== REVIEW ===')
  $file = Join-Path $out "$Id-$($res.Name).md"
  [IO.File]::WriteAllText($file, (($hdr -join "`n") + "`n" + ($res.Body -replace "`r", '') + "`n"), $utf8)
  $manifest += "$($res.Name): $Id-$($res.Name).md sha256=$((Get-FileHash $file -Algorithm SHA256).Hash)"
  Add-Content $log "$Id $($res.Name) $($res.Pinned) reported=$($res.Model) mode=$($res.Mode) fallbacks=$($res.Fallbacks) $($res.Secs)s exit=$($res.Exit) status=$(if ($res.Ok) { 'OK' } else { 'FAILED' }) prompt=$promptSource"
}
[IO.File]::WriteAllText((Join-Path $out "$Id-manifest.txt"), (($manifest -join "`n") + "`n"), $utf8)

& (Join-Path $o 'summarize.ps1') -Id $Id -OutDir $out
$sumExit = $LASTEXITCODE
if (-not $allOk) { Write-Error "reviewer FAILED (no VERDICT after retry); see headers in $out"; exit 2 }
if ($sumExit -ne 0) { exit $sumExit }
"Done. $out\$Id-summary.md"
