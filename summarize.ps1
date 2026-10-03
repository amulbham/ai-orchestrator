param(
  [Parameter(Mandatory)][string]$Id,
  [string]$OutDir = 'reviews'
)
# Mechanical, fail-closed summary. No judgment, no paraphrase. Reads ONLY reviewers named in <Id>-manifest.txt.
$o = $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding $false
$dir = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $o $OutDir }
$sumPath = Join-Path $dir "$Id-summary.md"
function Fail($lines) {
  $l = @("# $Id normalized summary - FAILED CLOSED (mechanically assembled by summarize.ps1)", '') + $lines + @('', 'No counts are reported.')
  [IO.File]::WriteAllText($sumPath, ($l -join "`n") + "`n", $utf8)
  $lines | ForEach-Object { Write-Host $_ }
  exit 1
}

$mf = Join-Path $dir "$Id-manifest.txt"
if (-not (Test-Path $mf)) { Fail @("MANIFEST MISSING: $mf") }
$M = @{}; $files = @{}
foreach ($ln in (Get-Content $mf)) {
  if ($ln -match '^(RunId|Id|Tier|Elevate|Commit|Reviewers):\s*(.*)$') { $M[$Matches[1]] = $Matches[2].Trim() }
  elseif ($ln -match '^(\w+):\s*(\S+)\s+sha256=([0-9A-Fa-f]{64})\s*$') { $files[$Matches[1]] = @{ File = $Matches[2]; Hash = $Matches[3] } }
}
if ($M['Id'] -ne $Id) { Fail @("STALE MANIFEST: manifest Id '$($M['Id'])' != '$Id'") }
if (-not $M['Reviewers'] -or -not $M['RunId']) { Fail @('MANIFEST MALFORMED: needs RunId and Reviewers') }
$names = @($M['Reviewers'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$R = @{}; $errs = @()
foreach ($n in $names) {
  $bad = @()
  if (-not $files.ContainsKey($n)) { $errs += "UNPARSED: $n (no file entry in manifest)"; continue }
  $p = Join-Path $dir $files[$n].File
  if (-not (Test-Path $p)) { $errs += "UNPARSED: $n (output missing: $($files[$n].File))"; continue }
  if ((Get-FileHash $p -Algorithm SHA256).Hash -ne $files[$n].Hash.ToUpper()) { $errs += "UNPARSED: $n (STALE: file hash does not match manifest)"; continue }
  $lines = [IO.File]::ReadAllText($p) -split "`r?`n"
  $bi = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '=== REVIEW ===') { $bi = $i; break } }
  if ($bi -lt 0) { $errs += "UNPARSED: $n (no '=== REVIEW ===' line; free-form output)"; continue }
  $H = @{}; for ($i = 0; $i -lt $bi; $i++) { if ($lines[$i] -match '^(\w+):\s*(.*)$') { $H[$Matches[1]] = $Matches[2] } }
  if ($H['RunId'] -ne $M['RunId']) { $errs += "UNPARSED: $n (STALE: header RunId does not match manifest)"; continue }
  if ($H['Status'] -ne 'OK') { $errs += "UNPARSED: $n (reviewer Status=$($H['Status']))"; continue }
  $findings = @(); $news = @(); $verdicts = @(); $lastNb = -1
  for ($i = $bi + 1; $i -lt $lines.Count; $i++) {
    $L = $lines[$i]; $no = $i + 1
    if ($L.Trim() -ne '') { $lastNb = $i }
    if ($L -match '^[\s>*_`#\-\d\.\)]*(FINDING|NEW|VERDICT)\b') {
      $kind = $Matches[1]
      if ($L -notmatch "^$kind") { $bad += "line ${no}: reserved prefix not at line start: $L"; continue }
      if ($kind -eq 'VERDICT') {
        if ($L -match '^VERDICT: (SEAL|REVISE)\s*$') { $verdicts += [pscustomobject]@{ No = $no; V = $Matches[1]; Idx = $i } } else { $bad += "line ${no}: malformed VERDICT: $L" }
        continue
      }
      $f = @($L -split '\|' | ForEach-Object { $_.Trim() })
      if ($kind -eq 'FINDING') {
        if ($f.Count -ne 6 -or ($f | Where-Object { $_ -eq '' })) { $bad += "line ${no}: FINDING needs exactly 6 non-empty |-separated fields: $L"; continue }
        if ($f[1] -notin 'BLOCKER','REQUIRED','OPTIONAL') { $bad += "line ${no}: bad class '$($f[1])'"; continue }
        $path = ($f[3] -replace '[`*]', '' -replace '\\', '/' -replace '^\./', '') -replace ':[\sLl\d,\-]+$', ''
        $sec = ($f[2] -replace '[`*]', '' -replace '\s+', ' ').ToLower().Trim()
        $findings += [pscustomobject]@{ No = $no; Class = $f[1]; Key = ($path.ToLower() + ' | ' + $sec); Raw = $L }
      } else {
        if ($f.Count -ne 3 -or ($f | Where-Object { $_ -eq '' })) { $bad += "line ${no}: NEW needs exactly 3 non-empty |-separated fields: $L"; continue }
        $news += [pscustomobject]@{ No = $no; Raw = $L }
      }
    }
  }
  if ($verdicts.Count -ne 1) { $bad += "expected exactly 1 valid VERDICT line, found $($verdicts.Count)" }
  elseif ($verdicts[0].Idx -ne $lastNb) { $bad += "line $($verdicts[0].No): VERDICT is not the last non-blank line" }
  else {
    $blk = @($findings | Where-Object { $_.Class -in 'BLOCKER','REQUIRED' }).Count
    if ($verdicts[0].V -eq 'REVISE' -and $blk -eq 0) { $bad += 'VERDICT REVISE with no BLOCKER/REQUIRED record' }
    if ($verdicts[0].V -eq 'SEAL' -and $blk -gt 0) { $bad += "VERDICT SEAL with $blk BLOCKER/REQUIRED record(s)" }
  }
  if ($bad.Count) { $errs += "UNPARSED: $n"; $bad | ForEach-Object { $errs += "  $_" }; continue }
  $R[$n] = @{ H = $H; F = $findings; N = $news; V = $verdicts[0].V }
}
if ($errs.Count) { Fail $errs }

# ---- grouping ----
$g = [ordered]@{ 'CONSENSUS' = @(); 'SEVERITY-SPLIT' = @(); 'AMBIGUOUS' = @() }
foreach ($n in $names) { $g["SINGLE-REVIEWER: $($n.ToUpper())-ONLY"] = @() }
$keys = @($names | ForEach-Object { $R[$_].F } | ForEach-Object { $_.Key } | Select-Object -Unique)
foreach ($k in $keys) {
  $per = @{}; foreach ($n in $names) { $per[$n] = @($R[$n].F | Where-Object { $_.Key -eq $k }) }
  $have = @($names | Where-Object { $per[$_].Count -gt 0 })
  if ($have.Count -eq 1) { $g["SINGLE-REVIEWER: $($have[0].ToUpper())-ONLY"] += , @{ Key = $k; Per = $per; Have = $have }; continue }
  $one = ($have | Where-Object { $per[$_].Count -ne 1 }).Count -eq 0
  if (-not $one) { $g['AMBIGUOUS'] += , @{ Key = $k; Per = $per; Have = $have } }
  elseif (@($have | ForEach-Object { $per[$_][0].Class } | Select-Object -Unique).Count -eq 1) { $g['CONSENSUS'] += , @{ Key = $k; Per = $per; Have = $have } }
  else { $g['SEVERITY-SPLIT'] += , @{ Key = $k; Per = $per; Have = $have } }
}

$el = if ($M['Elevate'] -eq 'True') { ' ELEVATED' } else { '' }
$s = @("# $Id normalized summary (mechanically assembled by summarize.ps1)$el", '', "RunId: $($M['RunId'])  Tier: $($M['Tier'])  Commit: $($M['Commit'])")
foreach ($n in $names) { $h = $R[$n].H; $s += "$n : model=$($h['ModelReported']) effort=$($h['EffortReported']) mode=$($h['Mode']) fallbacks=$($h['Fallbacks']) prompt=$($h['Prompt'])" }
$s += ''; $s += '## Verdicts'; foreach ($n in $names) { $s += "- $n : VERDICT: $($R[$n].V)" }
$s += ''; $s += '## Counts per reviewer'
foreach ($n in $names) { $c = { param($x) @($R[$n].F | Where-Object { $_.Class -eq $x }).Count }; $s += "- $n : BLOCKER $(& $c 'BLOCKER') / REQUIRED $(& $c 'REQUIRED') / OPTIONAL $(& $c 'OPTIONAL') / NEW $($R[$n].N.Count)" }
$s += ''; $s += '## Counts per group'
foreach ($k in $g.Keys) { $s += "- $k : $($g[$k].Count)" }
$s += "- NEW FINDINGS (NOT AUTHORIZED) : $(($names | ForEach-Object { $R[$_].N.Count } | Measure-Object -Sum).Sum)"
foreach ($k in $g.Keys) {
  $s += ''; $s += "## $k" + $(if ($k -eq 'CONSENSUS') { ' (Planner confirms each)' } elseif ($k -eq 'SEVERITY-SPLIT') { ' (Planner adjudicates)' } elseif ($k -eq 'AMBIGUOUS') { ' (unpaired, all listed)' } else { '' })
  if (-not $g[$k].Count) { $s += '(none)' }
  foreach ($e in $g[$k]) { $s += "### key: $($e.Key)"; foreach ($n in $e.Have) { foreach ($f in $e.Per[$n]) { $s += "- $n (line $($f.No)): $($f.Raw)" } } }
}
$s += ''; $s += '## NEW FINDINGS (NOT AUTHORIZED)'
$any = $false; foreach ($n in $names) { foreach ($x in $R[$n].N) { $any = $true; $s += "- $n (line $($x.No)): $($x.Raw)" } }
if (-not $any) { $s += '(none)' }
$s += ''; $s += '## PLANNER DISPOSITION'; $s += '(left empty for the planner)'
[IO.File]::WriteAllText($sumPath, ($s -join "`n") + "`n", $utf8)
Write-Host "Summary: $sumPath"
exit 0
