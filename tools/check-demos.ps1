# zzc baseline check: native dialect run output vs ejected pure-Zig build output.
#
# Usage (repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-demos.ps1
#
# For each demo project:
#   1) `zzc run`            capture the dialect program's raw stdout/stderr bytes
#   2) `zzc eject standard` export a standalone standard-Zig project
#   3) `zig build` inside it and run the produced executable, capturing raw bytes
# Compare bytes (encoding-independent) to prove dialect == graduated pure Zig.

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Output "== build zzc =="
zig build
if ($LASTEXITCODE -ne 0) { throw "zzc build failed" }
$isWin = ($env:OS -eq "Windows_NT")
$ext = if ($isWin) { ".exe" } else { "" }
$zzc = Join-Path $root ("zig-out/bin/zzc" + $ext)

function Read-B([string]$p) {
    if (Test-Path $p) { return [System.IO.File]::ReadAllBytes($p) } else { return @() }
}
function Same-Bytes([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}

$demos = @("hello", "syntax", "multi", "nested")
$fail = 0

foreach ($d in $demos) {
    $dir = Join-Path $root ("demo/" + $d)
    Set-Location $dir

    foreach ($sub in @(".zzc", "standard")) {
        $p = Join-Path $dir $sub
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }

    Write-Output ("== demo/" + $d + " ==")

    # 1) native dialect run
    $nOut = Join-Path $dir "_native.out"; $nErr = Join-Path $dir "_native.err"
    $rp = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $dir -RedirectStandardOutput $nOut -RedirectStandardError $nErr
    if ($rp.ExitCode -ne 0) { Write-Output ("  [FAIL] zzc run exit " + $rp.ExitCode); $fail = $fail + 1; continue }

    # 1b) `zzc check` must pass for a clean project (guards the multi-file check
    #     regression: library modules without `main` must not be build-exe'd alone).
    $cOut = Join-Path $dir "_check.out"; $cErr = Join-Path $dir "_check.err"
    $cp = Start-Process -FilePath $zzc -ArgumentList "check" -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $dir -RedirectStandardOutput $cOut -RedirectStandardError $cErr
    foreach ($t in @($cOut, $cErr)) { if (Test-Path $t) { Remove-Item -Force $t } }
    if ($cp.ExitCode -ne 0) { Write-Output ("  [FAIL] zzc check exit " + $cp.ExitCode); $fail = $fail + 1; continue }

    # 2) eject
    & $zzc eject standard 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Output ("  [FAIL] eject exit " + $LASTEXITCODE); $fail = $fail + 1; continue }

    # 3) build + run the ejected, standalone project
    $bin = Join-Path $dir "standard/zig-out/bin"
    $exe = Get-ChildItem -Recurse $bin -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".pdb" } | Select-Object -First 1
    if (-not $exe) { Write-Output "  [FAIL] no eject artifact found"; $fail = $fail + 1; continue }
    $eOut = Join-Path $dir "_eject.out"; $eErr = Join-Path $dir "_eject.err"
    $ep = Start-Process -FilePath $exe.FullName -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $dir -RedirectStandardOutput $eOut -RedirectStandardError $eErr
    if ($ep.ExitCode -ne 0) { Write-Output ("  [FAIL] ejected run exit " + $ep.ExitCode); $fail = $fail + 1; continue }

    $nbOut = Read-B $nOut; $nbErr = Read-B $nErr
    $ebOut = Read-B $eOut; $ebErr = Read-B $eErr
    $okOut = Same-Bytes $nbOut $ebOut
    $okErr = Same-Bytes $nbErr $ebErr

    foreach ($t in @($nOut, $nErr, $eOut, $eErr)) { if (Test-Path $t) { Remove-Item -Force $t } }

    if ($okOut -and $okErr) {
        $msg = [System.Text.Encoding]::UTF8.GetString($ebErr)
        Write-Output ("  [PASS] byte-identical output: " + $msg.Trim())
    } else {
        Write-Output ("  [FAIL] differs (stdout match=$okOut, stderr match=$okErr)")
        $fail = $fail + 1
    }
}

Set-Location $root

# --- D38 e2e guard (round 86 defect): `zzc run` whose user program exits with a
# NON-ZERO code takes the third exit path (std.process.exit) which historically
# skipped the dispatch-tail saveSymbols -> newly interned native mappings were
# silently lost. main.zig is outside the unit-test graph, so this behavioral
# contract is pinned end-to-end: faithful exit code 7 AND symbols.txt persisted.
# NOTE: this script must stay pure ASCII (PowerShell 5.1 -File misreads BOM-less
# UTF-8 as GBK); the native identifier is built from code points instead.
Write-Output "== d38 symbols-persistence guard =="
$g = Join-Path $root ".zig-cache/d38_guard"
if (Test-Path $g) { Remove-Item -Recurse -Force $g }
New-Item -ItemType Directory -Force -Path (Join-Path $g "src") | Out-Null
$natName = [string][char]0x6D4B + [string][char]0x8BD5 + [string][char]0x7B26 + [string][char]0x53F7 # cjk native identifier built from code points
$gsrc = @"
const std = @import("std");

pub fn main() !void {
    const $natName = 7;
    std.debug.print("{d}\n", .{$natName});
    std.process.exit(7);
}
"@
[System.IO.File]::WriteAllText((Join-Path $g "src\main.zz"), $gsrc, (New-Object System.Text.UTF8Encoding($false)))
$go = Join-Path $g "o.txt"; $ge = Join-Path $g "e.txt"
$gp = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $g -RedirectStandardOutput $go -RedirectStandardError $ge
$guardOk = $true
if ($gp.ExitCode -ne 7) { Write-Output ("  [FAIL] d38 guard: expected faithful exit code 7, got " + $gp.ExitCode); $guardOk = $false }
$symFile = Join-Path $g ".zzc\symbols.txt"
if (-not (Test-Path $symFile)) {
    Write-Output "  [FAIL] d38 guard: symbols.txt missing after run with non-zero user exit (third exit path swallowed saveSymbols)"
    $guardOk = $false
} else {
    $symTxt = [System.Text.Encoding]::UTF8.GetString((Read-B $symFile))
    if ($symTxt -notmatch '=\s*z_\d+') {
        Write-Output "  [FAIL] d38 guard: symbols.txt present but no persisted native->z_N mapping"
        $guardOk = $false
    }
}
if ($guardOk) { Write-Output "  [PASS] d38 guard: non-zero-exit run persisted symbol mapping; exit code 7 propagated faithfully" }
else { $fail = $fail + 1 }
Remove-Item -Recurse -Force $g -ErrorAction SilentlyContinue

# --- embed-asset staging guard (round 91, D2/D3/R8 contract): stageEmbedAssets
# mirrors @embedFile assets into the gen tree (in-root) and must SKIP targets
# that resolve outside the mirror root (out-of-root write guard). The function
# lives in main.zig (outside the unit-test graph) and its path-string ownership
# branches are invisible to unit tests, so pin both behavioral halves e2e.
# Script stays pure ASCII: CJK file names are built from code points.
Write-Output "== embed-staging guard =="
$assetName = [string][char]0x8D44 + [string][char]0x6E90 + ".txt"   # zi-yuan.txt (in-tree asset)
$escName   = [string][char]0x56FA + [string][char]0x8DEF + ".txt"   # pang-lu.txt (outside-tree escape target)
$encNoBom = New-Object System.Text.UTF8Encoding($false)
$guardOk = $true

# (A) positive half: in-tree asset is mirrored to .zzc/gen and run embeds it faithfully
$ga = Join-Path $root ".zig-cache/embedA_guard"
if (Test-Path $ga) { Remove-Item -Recurse -Force $ga }
New-Item -ItemType Directory -Force -Path (Join-Path $ga "src") | Out-Null
$assetBytes = $encNoBom.GetBytes("EMBED-ASSET-CONTENT-12345") # 25 bytes, ASCII for stable comparison
[System.IO.File]::WriteAllBytes((Join-Path $ga ("src\" + $assetName)), $assetBytes)
$gaSrc = @"
const std = @import("std");

const embedA = @embedFile("$assetName");

pub fn main() void {
    std.debug.print("{d}\n", .{embedA.len});
}
"@
[System.IO.File]::WriteAllText((Join-Path $ga "src\main.zz"), $gaSrc, $encNoBom)
$gao = Join-Path $ga "o.txt"; $gae = Join-Path $ga "e.txt"
$gap = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $ga -RedirectStandardOutput $gao -RedirectStandardError $gae
if ($gap.ExitCode -ne 0) { Write-Output ("  [FAIL] embedA guard: run of in-tree embed exited " + $gap.ExitCode); $guardOk = $false }
# std.debug.print writes to stderr: assert on the merged streams, order-insensitively.
# NB: Read-B collapses an empty byte[] to $null through the PS pipeline, so read
# the redirect files directly here (empty stdout is normal for debug.print).
$txtA = ""
foreach ($f in @($gao, $gae)) { if (Test-Path $f) { $ba = [System.IO.File]::ReadAllBytes($f); if ($ba.Length -gt 0) { $txtA += [System.Text.Encoding]::UTF8.GetString($ba) } } }
if ($txtA.Trim() -ne "25") { Write-Output ("  [FAIL] embedA guard: embedded content not faithful (output=" + $txtA.Trim() + ", expected 25)"); $guardOk = $false }
$mirror = Join-Path $ga (".zzc\gen\src\" + $assetName)
if (-not (Test-Path $mirror)) {
    Write-Output "  [FAIL] embedA guard: in-tree asset NOT mirrored into gen tree (staging broke)"
    $guardOk = $false
} elseif (((Read-B $mirror)).Length -ne $assetBytes.Length) {
    Write-Output "  [FAIL] embedA guard: mirrored asset byte length differs from source"
    $guardOk = $false
}
Remove-Item -Recurse -Force $ga -ErrorAction SilentlyContinue

# (B) negative half: an embed path resolving OUTSIDE the mirror root .zzc/gen
# must NOT be staged. ONE `../` is in-package-permitted (embedPathStaysWithin
# precedent: single .. landing inside root is allowed), so the escape shape needs
# TWO levels up: from .zzc/gen/src that lands at .zzc/<esc> — outside the root.
# The asset file sits beside the project dir (.zig-cache/<esc>) so the SOURCE is
# real (without the guard, staging would actually write it out => load-bearing).
$gb = Join-Path $root ".zig-cache/embedB_guard"
if (Test-Path $gb) { Remove-Item -Recurse -Force $gb }
New-Item -ItemType Directory -Force -Path (Join-Path $gb "src") | Out-Null
$escSide = Join-Path $root (".zig-cache\" + $escName)
[System.IO.File]::WriteAllBytes($escSide, $encNoBom.GetBytes("OUTSIDE"))
$gbSrc = @"
const std = @import("std");

const embedB = @embedFile("../../$escName");

pub fn main() void {
    std.debug.print("{d}\n", .{embedB.len});
}
"@
[System.IO.File]::WriteAllText((Join-Path $gb "src\main.zz"), $gbSrc, $encNoBom)
$gbp = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $gb -RedirectStandardOutput (Join-Path $gb "o.txt") -RedirectStandardError (Join-Path $gb "e.txt")
if ($gbp.ExitCode -eq 0) { Write-Output "  [FAIL] embedB guard: out-of-root embed unexpectedly exited 0"; $guardOk = $false }
# NB: inside @(...) the comma operator binds TIGHTER than +, so each element must
# carry its own parentheses; without them both strings collapse into one array
# element and the containment check silently never runs (round 91 violation probe).
foreach ($leak in @((".zzc\" + $escName), (".zzc\gen\" + $escName))) {
    if (Test-Path -LiteralPath (Join-Path $gb $leak)) {
        Write-Output ('  [FAIL] embedB guard: out-of-root embed WAS staged to ' + $leak + ' (containment guard missing)')
        $guardOk = $false
    }
}
Remove-Item -Force $escSide -ErrorAction SilentlyContinue
if ($guardOk) { Write-Output "  [PASS] embed-staging guard: in-tree asset mirrored faithfully; out-of-root target not staged" }
else { $fail = $fail + 1 }
Remove-Item -Recurse -Force $gb -ErrorAction SilentlyContinue

if ($fail -gt 0) { throw ("$fail demo(s)/guard(s) failed the baseline check") }
Write-Output "all demos: dialect and graduated Zig behave identically"
