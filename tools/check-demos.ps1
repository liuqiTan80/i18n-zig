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

# Native dialect keyword forms, built from code points (script must stay pure
# ASCII; PS 5.1 -File misreads BOM-less UTF-8 as GBK). Since round 99 the .zz
# purity gate rejects ASCII forms of keywords that have a native mapping, so the
# embedded guard sources below must be written in native word forms. Standard
# library paths (std/debug/print/process/exit/.len) are aliases/interop territory
# and stay ASCII. Local const is intentionally named ASCII `std` (not a keyword).
function Native([int[]]$cps) { -join ($cps | ForEach-Object { [char]$_ }) }
$N_const  = Native 0x5E38,0x6570            # chang-shu
$N_import = Native 0x5BFC,0x5165            # dao-ru  (@import)
$N_pub    = Native 0x516C,0x5F00            # gong-kai
$N_fn     = Native 0x51FD,0x6570            # han-shu
$N_main   = Native 0x4E3B,0x51FD,0x6570     # zhu-han-shu (main)
$N_void   = Native 0x7A7A                   # kong  (void)
$N_embed  = Native 0x5D4C,0x5165,0x6587,0x4EF6 # qian-ru-wen-jian (@embedFile)

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
$N_const std = $N_import("std");

$N_pub $N_fn $N_main() !$N_void {
    $N_const $natName = 7;
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
$N_const std = $N_import("std");

$N_const embedA = $N_embed("$assetName");

$N_pub $N_fn $N_main() $N_void {
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
$N_const std = $N_import("std");

$N_const embedB = $N_embed("../../$escName");

$N_pub $N_fn $N_main() $N_void {
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

# --- D46 e2e guard (round 101 defect, D38 twin on the bail path): failures that
# occur AFTER translation/interned new native names (check/build semantic errors,
# eject `.fail` graduation verify) take the bail noreturn exit, which historically
# persisted F3 (flushUntranslated) but NOT saveSymbols -> mappings silently lost.
# Pin both failure shapes e2e: non-zero exit preserved AND symbols.txt persisted.
# Script stays pure ASCII: native forms built from code points.
Write-Output "== d46 bail-persistence guard =="
$N_var_g = Native 0x53D8,0x91CF            # bian-liang (var)
$N_u8_g  = Native 0x5B57,0x8282            # zi-jie (u8)
$gA = Native 0x7532                        # jia
$gB = Native 0x4E59                        # yi
$d46Ok = $true

# (A) check with a semantic compile error (u8 out of range): translation+intern
# succeeds, zig build-exe fails -> error.Failed -> bail.
$ga46 = Join-Path $root ".zig-cache/d46A_guard"
if (Test-Path $ga46) { Remove-Item -Recurse -Force $ga46 }
New-Item -ItemType Directory -Force -Path (Join-Path $ga46 "src") | Out-Null
$g46SrcA = @"
$N_const ${gA}: $N_u8_g = 300;

$N_pub $N_fn $N_main() $N_void {
    _ = ${gA};
}
"@
[System.IO.File]::WriteAllText((Join-Path $ga46 "src\main.zz"), $g46SrcA, $encNoBom)
$gp46a = Start-Process -FilePath $zzc -ArgumentList "check" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $ga46 -RedirectStandardOutput (Join-Path $ga46 "o.txt") -RedirectStandardError (Join-Path $ga46 "e.txt")
if ($gp46a.ExitCode -ne 1) { Write-Output ("  [FAIL] d46 guard A: expected exit 1 on semantic error, got " + $gp46a.ExitCode); $d46Ok = $false }
$sym46a = Join-Path $ga46 ".zzc\symbols.txt"
if (-not (Test-Path $sym46a)) {
    Write-Output "  [FAIL] d46 guard A: symbols.txt missing after check failure (bail swallowed saveSymbols)"
    $d46Ok = $false
} else {
    $t46a = [System.Text.Encoding]::UTF8.GetString((Read-B $sym46a))
    if ($t46a -notmatch '=\s*z_\d+') {
        Write-Output "  [FAIL] d46 guard A: symbols.txt present but no interned native->z_N mapping"
        $d46Ok = $false
    }
}
Remove-Item -Recurse -Force $ga46 -ErrorAction SilentlyContinue

# (B) eject whose graduation `zig build` fails (undeclared native identifier
# passes the pure translation layer): dest artifacts are written, verifyBuild
# returns .fail -> error.Failed -> bail. Interned names must still persist.
$gb46 = Join-Path $root ".zig-cache/d46B_guard"
if (Test-Path $gb46) { Remove-Item -Recurse -Force $gb46 }
New-Item -ItemType Directory -Force -Path (Join-Path $gb46 "src") | Out-Null
$g46SrcB = "$N_pub $N_fn $N_main() $N_void { $N_var_g $gA = $gB; }`n"
[System.IO.File]::WriteAllText((Join-Path $gb46 "src\main.zz"), $g46SrcB, $encNoBom)
$gp46b = Start-Process -FilePath $zzc -ArgumentList "eject out" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $gb46 -RedirectStandardOutput (Join-Path $gb46 "o.txt") -RedirectStandardError (Join-Path $gb46 "e.txt")
if ($gp46b.ExitCode -ne 1) { Write-Output ("  [FAIL] d46 guard B: expected exit 1 on eject verify failure, got " + $gp46b.ExitCode); $d46Ok = $false }
$sym46b = Join-Path $gb46 ".zzc\symbols.txt"
if (-not (Test-Path $sym46b)) {
    Write-Output "  [FAIL] d46 guard B: symbols.txt missing after eject .fail (bail swallowed saveSymbols)"
    $d46Ok = $false
}
Remove-Item -Recurse -Force $gb46 -ErrorAction SilentlyContinue

if ($d46Ok) { Write-Output "  [PASS] d46 guard: post-intern failure exits (check error, eject .fail) persist symbols faithfully" }
else { $fail = $fail + 1 }

# --- eject `.no_zig` branch e2e guard (round 102; round-60 manual verification is
# hereby automated): with zig ABSENT from PATH, `zzc eject` must still exit 0, the
# graduation artifacts must be complete (build.zig + zon WITHOUT fingerprint), and
# both notices must stay in native wording (no raw error-name leak). Spawn failure
# of a missing argv[0] is deterministic on Windows/Linux alike; the section skips
# itself when zig is not on PATH at all (nothing to strip, outer build needs zig too).
# Script stays pure ASCII: notice strings built from code points for assertions.
Write-Output "== eject no-zig guard =="
$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($zigCmd) {
    $zigDir = Split-Path -Parent $zigCmd.Source
    $gz = Join-Path $root ".zig-cache/nozig_guard"
    if (Test-Path $gz) { Remove-Item -Recurse -Force $gz }
    New-Item -ItemType Directory -Force -Path (Join-Path $gz "src") | Out-Null
    $gzSrc = "$N_pub $N_fn $N_main() $N_void { }`n"
    [System.IO.File]::WriteAllText((Join-Path $gz "src\main.zz"), $gzSrc, $encNoBom)
    $savedPath = $env:PATH
    $env:PATH = ($savedPath -split ';' | Where-Object { $_ -ne $zigDir -and $_ -ne "" }) -join ';'
    $gzp = Start-Process -FilePath $zzc -ArgumentList "eject out" -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $gz -RedirectStandardOutput (Join-Path $gz "o.txt") -RedirectStandardError (Join-Path $gz "e.txt")
    $env:PATH = $savedPath
    $gzOk = $true
    if ($gzp.ExitCode -ne 0) { Write-Output ("  [FAIL] nozig guard: expected exit 0 on .no_zig path, got " + $gzp.ExitCode); $gzOk = $false }
    if (-not (Test-Path (Join-Path $gz "out\build.zig"))) { Write-Output "  [FAIL] nozig guard: build.zig not written on .no_zig path"; $gzOk = $false }
    $zonTxt = ""
    $zonP = Join-Path $gz "out\build.zig.zon"
    if (Test-Path $zonP) { $zonTxt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($zonP)) } else { Write-Output "  [FAIL] nozig guard: build.zig.zon not written"; $gzOk = $false }
    if ($zonTxt.Contains("fingerprint")) { Write-Output "  [FAIL] nozig guard: zon carries fingerprint despite no zig to probe a legal value"; $gzOk = $false }
    # assertions: stdout must contain "wei-jian-ce-dao" (not-detected); stderr must NOT leak ASCII 'zzc:'-free raw names,
    # and must contain "wei-neng-xiang" (could-not-query) native hint.
    $oTxt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $gz "o.txt")))
    $eTxt = [System.IO.File]::ReadAllBytes((Join-Path $gz "e.txt"))
    $sTxt = if ($eTxt.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($eTxt) } else { "" }
    if (-not $oTxt.Contains((Native 0x672A,0x68C0,0x6D4B,0x5230))) { Write-Output "  [FAIL] nozig guard: native not-detected notice missing from stdout"; $gzOk = $false }
    if (-not $sTxt.Contains((Native 0x672A,0x80FD,0x5411))) { Write-Output "  [FAIL] nozig guard: native could-not-query fingerprint hint missing from stderr"; $gzOk = $false }
    if ($gzOk) { Write-Output "  [PASS] nozig guard: zig-absent eject exits 0 with complete artifacts and native notices" }
    else { $fail = $fail + 1 }
    Remove-Item -Recurse -Force $gz -ErrorAction SilentlyContinue
} else {
    Write-Output "  [SKIP] nozig guard: zig not on PATH (nothing to strip)"
}

if ($fail -gt 0) { throw ("$fail demo(s)/guard(s) failed the baseline check") }
Write-Output "all demos: dialect and graduated Zig behave identically"
