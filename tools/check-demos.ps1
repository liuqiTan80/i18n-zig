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

if ($fail -gt 0) { throw ("$fail demo(s)/guard(s) failed the baseline check") }
Write-Output "all demos: dialect and graduated Zig behave identically"
