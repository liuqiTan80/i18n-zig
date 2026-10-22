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
#
# Cross-platform (round 133, D52): runs under powershell 5.1 (Windows) AND pwsh
# on Linux, matching the CI matrix. All relative path fragments below use POSIX
# "/" through Join-Path -- on Unix pwsh a backslash is a LITERAL FILENAME
# character, so "src/main.zz" would create/read a single stray file and the
# out-of-root containment asserts would silently never fire (false green).

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Repo-wide fmt gate (round 133): closes the round-83 blind spot where every
# green-gate run only checked touched files under src/, so build.zig formatting
# drift survived 70+ rounds UNCAUGHT and ci.yml had no fmt step at all. Scans
# every tracked-source .zig/.zon while excluding generated caches and the probe
# sandbox (round-133 self-capture: a fresh-test --cache-dir under _probe holds
# non-formatted generated .zig and would trip the gate as a false positive).
Write-Output "== fmt gate (repo-wide, caches excluded) =="
$fmtTargets = Get-ChildItem -Recurse -File -Include *.zig,*.zon | Where-Object {
    $f = $_.FullName -replace '\\', '/'
    $f -notmatch '/(#?\.git|\.zig-cache|zig-out|\.zzc|_probe)(/|$)'
}
zig fmt --check $fmtTargets.FullName
if ($LASTEXITCODE -ne 0) { throw "zig fmt --check failed: repo formatting drift" }

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
$N_int32  = Native 0x4E2D,0x6574,0x6570     # zhong-zheng-shu (i32)
$N_ret    = Native 0x8FD4,0x56DE            # fan-hui (return)
$N_dezhi  = Native 0x5F97,0x503C            # de-zhi (identifier: library fn name; must not be a keyword form)

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
[System.IO.File]::WriteAllText((Join-Path $g "src/main.zz"), $gsrc, (New-Object System.Text.UTF8Encoding($false)))
$go = Join-Path $g "o.txt"; $ge = Join-Path $g "e.txt"
$gp = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $g -RedirectStandardOutput $go -RedirectStandardError $ge
$guardOk = $true
if ($gp.ExitCode -ne 7) { Write-Output ("  [FAIL] d38 guard: expected faithful exit code 7, got " + $gp.ExitCode); $guardOk = $false }
$symFile = Join-Path $g ".zzc/symbols.txt"
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
[System.IO.File]::WriteAllBytes((Join-Path $ga ("src/" + $assetName)), $assetBytes)
$gaSrc = @"
$N_const std = $N_import("std");

$N_const embedA = $N_embed("$assetName");

$N_pub $N_fn $N_main() $N_void {
    std.debug.print("{d}\n", .{embedA.len});
}
"@
[System.IO.File]::WriteAllText((Join-Path $ga "src/main.zz"), $gaSrc, $encNoBom)
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
$mirror = Join-Path $ga (".zzc/gen/src/" + $assetName)
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
# TWO levels up: from .zzc/gen/src that lands at .zzc/<esc> -- outside the root.
# The asset file sits beside the project dir (.zig-cache/<esc>) so the SOURCE is
# real (without the guard, staging would actually write it out => load-bearing).
$gb = Join-Path $root ".zig-cache/embedB_guard"
if (Test-Path $gb) { Remove-Item -Recurse -Force $gb }
New-Item -ItemType Directory -Force -Path (Join-Path $gb "src") | Out-Null
$escSide = Join-Path $root (".zig-cache/" + $escName)
[System.IO.File]::WriteAllBytes($escSide, $encNoBom.GetBytes("OUTSIDE"))
$gbSrc = @"
$N_const std = $N_import("std");

$N_const embedB = $N_embed("../../$escName");

$N_pub $N_fn $N_main() $N_void {
    std.debug.print("{d}\n", .{embedB.len});
}
"@
[System.IO.File]::WriteAllText((Join-Path $gb "src/main.zz"), $gbSrc, $encNoBom)
$gbp = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $gb -RedirectStandardOutput (Join-Path $gb "o.txt") -RedirectStandardError (Join-Path $gb "e.txt")
if ($gbp.ExitCode -eq 0) { Write-Output "  [FAIL] embedB guard: out-of-root embed unexpectedly exited 0"; $guardOk = $false }
# NB: inside @(...) the comma operator binds TIGHTER than +, so each element must
# carry its own parentheses; without them both strings collapse into one array
# element and the containment check silently never runs (round 91 violation probe).
foreach ($leak in @((".zzc/" + $escName), (".zzc/gen/" + $escName))) {
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
[System.IO.File]::WriteAllText((Join-Path $ga46 "src/main.zz"), $g46SrcA, $encNoBom)
$gp46a = Start-Process -FilePath $zzc -ArgumentList "check" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $ga46 -RedirectStandardOutput (Join-Path $ga46 "o.txt") -RedirectStandardError (Join-Path $ga46 "e.txt")
if ($gp46a.ExitCode -ne 1) { Write-Output ("  [FAIL] d46 guard A: expected exit 1 on semantic error, got " + $gp46a.ExitCode); $d46Ok = $false }
$sym46a = Join-Path $ga46 ".zzc/symbols.txt"
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
[System.IO.File]::WriteAllText((Join-Path $gb46 "src/main.zz"), $g46SrcB, $encNoBom)
$gp46b = Start-Process -FilePath $zzc -ArgumentList "eject out" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $gb46 -RedirectStandardOutput (Join-Path $gb46 "o.txt") -RedirectStandardError (Join-Path $gb46 "e.txt")
if ($gp46b.ExitCode -ne 1) { Write-Output ("  [FAIL] d46 guard B: expected exit 1 on eject verify failure, got " + $gp46b.ExitCode); $d46Ok = $false }
$sym46b = Join-Path $gb46 ".zzc/symbols.txt"
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
    [System.IO.File]::WriteAllText((Join-Path $gz "src/main.zz"), $gzSrc, $encNoBom)
    # PATH entries are split on the platform separator: on Linux it is ':' while
    # ';' is part of every single entry -- hard-coding ';' would leave zig on PATH
    # and the whole .no_zig branch would silently never be exercised (D52).
    $psSep = [System.IO.Path]::PathSeparator
    $savedPath = $env:PATH
    $env:PATH = ($savedPath -split [regex]::Escape($psSep) | Where-Object { $_ -ne $zigDir -and $_ -ne "" }) -join $psSep
    $gzp = Start-Process -FilePath $zzc -ArgumentList "eject out" -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $gz -RedirectStandardOutput (Join-Path $gz "o.txt") -RedirectStandardError (Join-Path $gz "e.txt")
    $env:PATH = $savedPath
    $gzOk = $true
    if ($gzp.ExitCode -ne 0) { Write-Output ("  [FAIL] nozig guard: expected exit 0 on .no_zig path, got " + $gzp.ExitCode); $gzOk = $false }
    if (-not (Test-Path (Join-Path $gz "out/build.zig"))) { Write-Output "  [FAIL] nozig guard: build.zig not written on .no_zig path"; $gzOk = $false }
    $zonTxt = ""
    $zonP = Join-Path $gz "out/build.zig.zon"
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

# --- R9g external lang-pack `--lang-file` e2e guard (round 103; also pins D47: a
# keywords-section `X = main` entry form must translate to main, not be declaration-
# position-avoided into z_N which silently degrades check into a library-style shallow
# pass). Three shapes: A positive (external minimal ja pack loads, gen contains
# `pub fn main(`, exit 0); B `$format` too new refused with native upgrade hint;
# C `--lang` + `--lang-file` mutual exclusion exits 2. Fixture data lives in
# tools/fixtures (outside the packs/ auto-discovery scan, never in the registry).
Write-Output "== external lang-pack guard =="
$fx = Join-Path $root "tools/fixtures"
$gr = Join-Path $root ".zig-cache/r9g_guard"
if (Test-Path $gr) { Remove-Item -Recurse -Force $gr }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $gr) | Out-Null
Copy-Item (Join-Path $fx "proj-ja") $gr -Recurse
$r9Ok = $true
# A: positive load + entry translation actually reached (deep check shape)
$pA = Start-Process -FilePath $zzc -ArgumentList @("check", "--lang-file", (Join-Path $fx "external-min.txt")) -NoNewWindow -Wait -PassThru -WorkingDirectory $gr `
    -RedirectStandardOutput (Join-Path $gr "a.o.txt") -RedirectStandardError (Join-Path $gr "a.e.txt")
if ($pA.ExitCode -ne 0) { Write-Output ("  [FAIL] r9g A: external pack check expected exit 0, got " + $pA.ExitCode); $r9Ok = $false }
$genZig = Join-Path $gr ".zzc/gen/src/main.zig"
$genTxt = if (Test-Path $genZig) { [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($genZig)) } else { "" }
# line-start assert, not any substring: a source comment holding the target literal gets transpiled into gen, so Contains false-hits (the silent-idle shape caught in the disproof round).
$hasMainFn = (@($genTxt -split "`n" | Where-Object { $_.StartsWith("pub fn main(") -or $_.StartsWith("fn main(") }).Count -gt 0)
if (-not $hasMainFn) { Write-Output "  [FAIL] r9g A/D47: keywords-section main form not translated at entry position (silent library-shape pass)"; $r9Ok = $false }
# B: $format too new -> refused with native upgrade hint (qing-sheng-ji via code points)
$pB = Start-Process -FilePath $zzc -ArgumentList @("check", "--lang-file", (Join-Path $fx "external-toofmt.txt")) -NoNewWindow -Wait -PassThru -WorkingDirectory $gr `
    -RedirectStandardOutput (Join-Path $gr "b.o.txt") -RedirectStandardError (Join-Path $gr "b.e.txt")
$bErr = [System.IO.File]::ReadAllBytes((Join-Path $gr "b.e.txt"))
$bTxt = if ($bErr.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($bErr) } else { "" }
if ($pB.ExitCode -ne 1) { Write-Output ("  [FAIL] r9g B: format-too-new expected exit 1, got " + $pB.ExitCode); $r9Ok = $false }
if (-not $bTxt.Contains((Native 0x8BF7,0x5347,0x7EA7))) { Write-Output "  [FAIL] r9g B: native upgrade hint missing from stderr"; $r9Ok = $false }
if ($bTxt.Contains("error: Failed")) { Write-Output "  [FAIL] r9g B: raw error name / stack trace leaked (bail-shape required)"; $r9Ok = $false }
# C: --lang and --lang-file together -> usage exit 2
$pC = Start-Process -FilePath $zzc -ArgumentList @("check", "--lang", "zh", "--lang-file", (Join-Path $fx "external-min.txt")) -NoNewWindow -Wait -PassThru -WorkingDirectory $gr `
    -RedirectStandardOutput (Join-Path $gr "c.o.txt") -RedirectStandardError (Join-Path $gr "c.e.txt")
if ($pC.ExitCode -ne 2) { Write-Output ("  [FAIL] r9g C: mutually-exclusive flags expected exit 2, got " + $pC.ExitCode); $r9Ok = $false }
if ($r9Ok) { Write-Output "  [PASS] r9g guard: external pack loads, entry form translates, format-too-new refused natively, flags mutually exclusive" }
else { $fail = $fail + 1 }
Remove-Item -Recurse -Force $gr -ErrorAction SilentlyContinue

# --- R104 `zzc init` scaffold e2e guard (round 104; pins D48: the emitted template must
# pass the tool's OWN purity gate -- round 99 dogfood missed cmdInit's hardcoded `!void`,
# so a freshly init-ed project failed `zzc check` at birth). Three shapes: A success form
# exits 0, writes src/main.zz, and the written project then checks clean (behavioral
# assertion, no substring traps per round-103 lesson: template comments pass through to
# gen verbatim); B no-overwrite: sentinel survives re-init with native hint; C unsafe name
# exits 2 with native hint and zero side effects (no stray src/ in workspace).
Write-Output "== init scaffold guard =="
$ig = Join-Path $root ".zig-cache/init_guard"
if (Test-Path $ig) { Remove-Item -Recurse -Force $ig }
New-Item -ItemType Directory -Force -Path $ig | Out-Null
$igOk = $true
# A: init + self-check of the emitted project
$pA = Start-Process -FilePath $zzc -ArgumentList @("init", "probe_proj") -NoNewWindow -Wait -PassThru -WorkingDirectory $ig `
    -RedirectStandardOutput (Join-Path $ig "a.o.txt") -RedirectStandardError (Join-Path $ig "a.e.txt")
if ($pA.ExitCode -ne 0) { Write-Output ("  [FAIL] init A: expected exit 0, got " + $pA.ExitCode); $igOk = $false }
$tmpl = Join-Path $ig "probe_proj/src/main.zz"
if (-not (Test-Path $tmpl)) { Write-Output "  [FAIL] init A: src/main.zz not written"; $igOk = $false }
$aOut = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $ig "a.o.txt")))
if (-not $aOut.Contains((Native 0x5DF2,0x521B,0x5EFA))) { Write-Output "  [FAIL] init A: native created-notice missing from stdout"; $igOk = $false }
# the D48 crux: the project the tool just scaffolded must pass the tool's own check
$proj = Join-Path $ig "probe_proj"
$pA2 = Start-Process -FilePath $zzc -ArgumentList @("check", "src/main.zz") -NoNewWindow -Wait -PassThru -WorkingDirectory $proj `
    -RedirectStandardOutput (Join-Path $ig "a2.o.txt") -RedirectStandardError (Join-Path $ig "a2.e.txt")
if ($pA2.ExitCode -ne 0) { Write-Output ("  [FAIL] init A/D48: freshly-init-ed project fails its own check (exit " + $pA2.ExitCode + ") - template drifted into a form the tool rejects"); $igOk = $false }
# B: no-overwrite (non-destructive idempotence) - sentinel must survive
Add-Content -Path $tmpl -Value "# SENTINEL-KEEP-ME" -Encoding UTF8
$pB = Start-Process -FilePath $zzc -ArgumentList @("init", "probe_proj") -NoNewWindow -Wait -PassThru -WorkingDirectory $ig `
    -RedirectStandardOutput (Join-Path $ig "b.o.txt") -RedirectStandardError (Join-Path $ig "b.e.txt")
$bOut = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Join-Path $ig "b.o.txt")))
$bContent = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($tmpl))
if ($pB.ExitCode -ne 0) { Write-Output ("  [FAIL] init B: re-init expected exit 0, got " + $pB.ExitCode); $igOk = $false }
if (-not $bOut.Contains((Native 0x672A,0x8986,0x76D6))) { Write-Output "  [FAIL] init B: native no-overwrite hint missing from stdout"; $igOk = $false }
if (-not $bContent.Contains("SENTINEL-KEEP-ME")) { Write-Output "  [FAIL] init B: existing project content was overwritten (destructive re-init)"; $igOk = $false }
# C: unsafe name -> exit 2 + native hint + zero side effects
$pC = Start-Process -FilePath $zzc -ArgumentList @("init", "..") -NoNewWindow -Wait -PassThru -WorkingDirectory $ig `
    -RedirectStandardOutput (Join-Path $ig "c.o.txt") -RedirectStandardError (Join-Path $ig "c.e.txt")
$cErr = [System.IO.File]::ReadAllBytes((Join-Path $ig "c.e.txt"))
$cTxt = if ($cErr.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($cErr) } else { "" }
if ($pC.ExitCode -ne 2) { Write-Output ("  [FAIL] init C: unsafe name expected exit 2, got " + $pC.ExitCode); $igOk = $false }
if (-not $cTxt.Contains((Native 0x4E0D,0x5B89,0x5168))) { Write-Output "  [FAIL] init C: native unsafe-name hint missing from stderr"; $igOk = $false }
# escape shape `init ..` would write ../src/main.zz, i.e. .zig-cache/src in the workspace parent
if (Test-Path (Join-Path $root ".zig-cache/src")) { Write-Output "  [FAIL] init C: reject happened AFTER side effects (escape wrote src/ into the parent dir)"; $igOk = $false }
# D (round 142, template i18n): a NON-default language pack must still yield a scaffold that
# passes the tool's OWN check at birth. Pre-142 the template was a hardcoded Chinese constant, so
# `init --lang-file <ja pack>` interned every Chinese token and the fresh project failed `check`
# at birth (probe T2: "expected ',' after field", exit 1). external-min.txt is a B6-contract ja
# pack WITHOUT void/i64/std/print mappings -> scaffold must ASCII-fallback those slots and still
# be born-legal. Script stays pure ASCII: the pack lives in tools/fixtures (data, not literals).
$fxMin = Join-Path $fx "external-min.txt"
$pD = Start-Process -FilePath $zzc -ArgumentList @("init", "probe_foreign", "--lang-file", $fxMin) -NoNewWindow -Wait -PassThru -WorkingDirectory $ig `
    -RedirectStandardOutput (Join-Path $ig "d.o.txt") -RedirectStandardError (Join-Path $ig "d.e.txt")
if ($pD.ExitCode -ne 0) { Write-Output ("  [FAIL] init D: foreign-pack init expected exit 0, got " + $pD.ExitCode); $igOk = $false }
$dTmpl = Join-Path $ig "probe_foreign/src/main.zz"
if (-not (Test-Path $dTmpl)) { Write-Output "  [FAIL] init D: foreign-pack src/main.zz not written"; $igOk = $false }
$dProj = Join-Path $ig "probe_foreign"
$pD2 = Start-Process -FilePath $zzc -ArgumentList @("check", "src/main.zz", "--lang-file", $fxMin) -NoNewWindow -Wait -PassThru -WorkingDirectory $dProj `
    -RedirectStandardOutput (Join-Path $ig "d2.o.txt") -RedirectStandardError (Join-Path $ig "d2.e.txt")
if ($pD2.ExitCode -ne 0) { Write-Output ("  [FAIL] init D: foreign-pack freshly-init-ed project fails its own check (exit " + $pD2.ExitCode + ") - template not generated per selected pack"); $igOk = $false }
if ($igOk) { Write-Output "  [PASS] init guard: scaffold passes own purity gate (D48), re-init non-destructive, unsafe names exit 2 before any write, foreign-pack scaffold born-legal (142)" }
else { $fail = $fail + 1 }
Remove-Item -Recurse -Force $ig -ErrorAction SilentlyContinue

# --- `zzc run -- <prog_args>` argument-forwarding e2e guard (round 130): the `--`
# split lives in cmdBuild (main.zig, OUTSIDE the unit-test graph). Everything after
# `--` is routed into the user program's argv and the `--` itself is consumed; the
# built exe is spawned with stdio .inherit (dialect stdout streams straight through).
# No existing guard ever feeds prog_args -- d38 runs a bare `zzc run` and the four
# byte-identity demos pass no `--`. So a regression that DROPS the forwarding (argc
# pinned at 1) or LEAKS `--` into argv (argc off-by-one) is invisible to every current
# check. Pin two shapes e2e via the program's own argv count: bare run -> argc=1;
# `run -- alpha beta gamma` -> argc=4 (three words forwarded, the `--` consumed).
# The reader program takes the Zig 0.17 `std.process.Init` param and calls
# `ini.minimal.args.toSlice(...)` (Init exposes args only under `.minimal`, not flat).
# Script stays pure ASCII: native keyword forms built from code points (PS 5.1 -File
# misreads BOM-less UTF-8 as GBK); `try` is a purity-gated keyword so it must be native.
Write-Output "== run prog_args forwarding guard =="
$N_try_r = Native 0x5C1D,0x8BD5              # chang-shi (try)
$ra = Join-Path $root ".zig-cache/runargs_guard"
if (Test-Path $ra) { Remove-Item -Recurse -Force $ra }
New-Item -ItemType Directory -Force -Path (Join-Path $ra "src") | Out-Null
$raSrc = @"
$N_const std = $N_import("std");

$N_pub $N_fn $N_main(ini: std.process.Init) !$N_void {
    $N_const arr = $N_try_r ini.minimal.args.toSlice(ini.arena.allocator());
    std.debug.print("argc={d}", .{arr.len});
}
"@
[System.IO.File]::WriteAllText((Join-Path $ra "src/main.zz"), $raSrc, $encNoBom)
$raOk = $true

# reads the argv count the user program echoed back through the inherited stderr
function Argc-Of([string]$f) {
    if (-not (Test-Path $f)) { return -1 }
    $t = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($f))
    $m = [regex]::Match($t, "argc=(\d+)")
    if ($m.Success) { return [int]$m.Groups[1].Value } else { return -1 }
}

# (A) bare run: argv holds only the program name -> argc == 1
$raAe = Join-Path $ra "a.err"; $raAo = Join-Path $ra "a.out"
$pA = Start-Process -FilePath $zzc -ArgumentList "run" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $ra -RedirectStandardOutput $raAo -RedirectStandardError $raAe
$argcA = Argc-Of $raAe
if ($pA.ExitCode -ne 0) { Write-Output ("  [FAIL] runargs A: bare run exited " + $pA.ExitCode); $raOk = $false }
if ($argcA -ne 1) { Write-Output ("  [FAIL] runargs A: bare run expected argc=1 (program name only), got " + $argcA); $raOk = $false }

# (B) `run -- alpha beta gamma`: three words forwarded and the `--` consumed -> argc == 4
$raBe = Join-Path $ra "b.err"; $raBo = Join-Path $ra "b.out"
$pB = Start-Process -FilePath $zzc -ArgumentList @("run","--","alpha","beta","gamma") -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $ra -RedirectStandardOutput $raBo -RedirectStandardError $raBe
$argcB = Argc-Of $raBe
if ($pB.ExitCode -ne 0) { Write-Output ("  [FAIL] runargs B: run with prog_args exited " + $pB.ExitCode); $raOk = $false }
if ($argcB -ne 4) { Write-Output ("  [FAIL] runargs B: expected argc=4 (name + 3 forwarded, the `--` consumed), got " + $argcB); $raOk = $false }

if ($raOk) { Write-Output "  [PASS] runargs guard: bare run argc=1; `zzc run -- a b c` forwards prog_args (argc=4) and consumes the `--` (stdio .inherit stream reaches parent)" }
else { $fail = $fail + 1 }
Remove-Item -Recurse -Force $ra -ErrorAction SilentlyContinue

# --- top-level dispatch exit-code contract guard (round 131): the command router lives
# in main.zig (OUTSIDE the unit-test graph), so no unit test can see a regression here.
# Two twin faces are pinned: (A) an unknown/typo'd subcommand (e.g. `zzc runn`) MUST fail
# with exit 2 and a native hint on stderr and nothing on stdout -- the old `return`->exit 0
# (main.zig L1000-1003) let CI/scripts misjudge a typo as success; (B) its twin: help flags
# (--help/-h/-?/help), a bare invocation and `version` MUST exit 0 with usage/info on stdout
# and never fall through to the unknown-subcommand exit 2 (removing the help branch would
# silently turn `zzc --help` into exit 2). Existing guards test exit 2 only for --lang
# mutual exclusion and unsafe init names, never the unknown-subcommand path nor help->0.
Write-Output "== dispatch exit-code contract guard =="
$dkOk = $true
function Read-T([string]$f) {
    if (-not (Test-Path $f)) { return "" }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($f))
}
$N_zimling = Native 0x5B50,0x547D,0x4EE4   # zi-ming-ling (sub-command), from the native usage hint
# (A) unknown/typo subcommands -> exit 2, native hint on stderr, stdout clean
foreach ($bad in @("runn", "bulid", "chekc")) {
    $oa = Join-Path $root (".zig-cache/dkA_" + $bad + ".out"); $ea = Join-Path $root (".zig-cache/dkA_" + $bad + ".err")
    $pa = Start-Process -FilePath $zzc -ArgumentList $bad -NoNewWindow -Wait -PassThru -RedirectStandardOutput $oa -RedirectStandardError $ea
    $ta = Read-T $ea; $sa = Read-T $oa
    if ($pa.ExitCode -ne 2) { Write-Output ("  [FAIL] dispatch A: unknown subcommand '" + $bad + "' expected exit 2 (anti-CI-misjudge), got " + $pa.ExitCode); $dkOk = $false }
    if (-not $ta.Contains($N_zimling)) { Write-Output ("  [FAIL] dispatch A: unknown '" + $bad + "' missing native 'zi-ming-ling' hint on stderr"); $dkOk = $false }
    if ($sa.Trim().Length -ne 0) { Write-Output ("  [FAIL] dispatch A: unknown '" + $bad + "' leaked text to stdout (hint must be stderr-only)"); $dkOk = $false }
    Remove-Item -Force $oa, $ea -ErrorAction SilentlyContinue
}
# (B) help flags -> exit 0 + usage on stdout (twin of the unknown->2 branch)
foreach ($good in @("--help", "-h", "-?", "help")) {
    $ob = Join-Path $root ".zig-cache/dkB.out"; $eb = Join-Path $root ".zig-cache/dkB.err"
    $pb = Start-Process -FilePath $zzc -ArgumentList $good -NoNewWindow -Wait -PassThru -RedirectStandardOutput $ob -RedirectStandardError $eb
    $sb = Read-T $ob
    if ($pb.ExitCode -ne 0) { Write-Output ("  [FAIL] dispatch B: help flag '" + $good + "' expected exit 0 (must not fall through to unknown->2), got " + $pb.ExitCode); $dkOk = $false }
    if ($sb.Trim().Length -eq 0) { Write-Output ("  [FAIL] dispatch B: help flag '" + $good + "' printed empty stdout usage"); $dkOk = $false }
    Remove-Item -Force $ob, $eb -ErrorAction SilentlyContinue
}
# (C) bare invocation (no args) -> exit 0 + usage on stdout
$oc = Join-Path $root ".zig-cache/dkC.out"; $occ = Join-Path $root ".zig-cache/dkC.err"
$pc = Start-Process -FilePath $zzc -NoNewWindow -Wait -PassThru -RedirectStandardOutput $oc -RedirectStandardError $occ
if ($pc.ExitCode -ne 0) { Write-Output ("  [FAIL] dispatch C: bare invocation expected exit 0, got " + $pc.ExitCode); $dkOk = $false }
if ((Read-T $oc).Trim().Length -eq 0) { Write-Output "  [FAIL] dispatch C: bare invocation printed empty stdout usage"; $dkOk = $false }
Remove-Item -Force $oc, $occ -ErrorAction SilentlyContinue
# (D) version -> exit 0 + non-empty stdout
$od = Join-Path $root ".zig-cache/dkD.out"; $ed = Join-Path $root ".zig-cache/dkD.err"
$pd = Start-Process -FilePath $zzc -ArgumentList "version" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $od -RedirectStandardError $ed
if ($pd.ExitCode -ne 0) { Write-Output ("  [FAIL] dispatch D: version expected exit 0, got " + $pd.ExitCode); $dkOk = $false }
if ((Read-T $od).Trim().Length -eq 0) { Write-Output "  [FAIL] dispatch D: version printed empty stdout"; $dkOk = $false }
Remove-Item -Force $od, $ed -ErrorAction SilentlyContinue
if ($dkOk) { Write-Output "  [PASS] dispatch guard: unknown/typo subcommands exit 2 with native hint (stdout clean); help-flags/bare/version exit 0 with usage on stdout" }
else { $fail = $fail + 1 }

# --- `zzc build` exit-code / artifact / native-hint contract guard (round 132): the
# .build branch of cmdBuild (main.zig L536-616, OUTSIDE the unit-test graph) had ZERO
# e2e coverage -- the demos main chain only runs `run`/`check`/`eject`, and d46 pins
# the exit-1 bail shape only for check/eject failures. `error: Failed` non-leak was
# asserted only on the r9g external-pack path. Two faces pinned here: (A) a clean
# source builds with exit 0, a NATIVE artifact hint on stdout ("chan-wu"), and the
# produced .zzc/bin exe is real and runs standalone; (B) a semantic-error source
# exits 1 (not 0 = anti-CI-misjudge, not 2 = not a usage error), localizes the diag
# natively on stderr ("cuo-wu" prefix), keeps stdout clean, leaks no raw error name,
# and emits no artifact. Script stays pure ASCII; native words from code points.
Write-Output "== build exit-code & artifact guard =="
$bldOk = $true
$N_chanhao = Native 0x4EA7,0x7269          # chan-wu (artifact), native success hint
$N_cuowu   = Native 0x9519,0x8BEF          # cuo-wu (error), native diag prefix
# (A) clean source -> exit 0 + native hint on stdout + runnable artifact
$bA = Join-Path $root ".zig-cache/bldA_guard"
if (Test-Path $bA) { Remove-Item -Recurse -Force $bA }
New-Item -ItemType Directory -Force -Path (Join-Path $bA "src") | Out-Null
$bSrcA = @"
$N_const std = $N_import("std");

$N_pub $N_fn $N_main() $N_void {
    std.debug.print("ok132", .{});
}
"@
[System.IO.File]::WriteAllText((Join-Path $bA "src/main.zz"), $bSrcA, $encNoBom)
$bAo = Join-Path $bA "a.out"; $bAe = Join-Path $bA "a.err"
$bpA = Start-Process -FilePath $zzc -ArgumentList "build" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $bA -RedirectStandardOutput $bAo -RedirectStandardError $bAe
if ($bpA.ExitCode -ne 0) { Write-Output ("  [FAIL] build A: clean build expected exit 0, got " + $bpA.ExitCode); $bldOk = $false }
if (-not (Read-T $bAo).Contains($N_chanhao)) { Write-Output "  [FAIL] build A: native 'chan-wu' artifact hint missing from stdout"; $bldOk = $false }
# artifact name is os-gated exactly like the product (main.zig L557:
# builtin.os.tag == .windows ? .exe : ""); hard-coding main.exe would miss the
# extension-less Linux artifact and turn both artifact asserts false (D52).
$bExe = (Join-Path $bA ".zzc/bin/main") + $ext
if (-not (Test-Path $bExe)) { Write-Output "  [FAIL] build A: artifact missing under .zzc/bin (emit-bin wiring broken)"; $bldOk = $false }
else {
    $beo = Join-Path $bA "exe.out"; $bee = Join-Path $bA "exe.err"
    $pe = Start-Process -FilePath $bExe -NoNewWindow -Wait -PassThru -RedirectStandardOutput $beo -RedirectStandardError $bee
    if ($pe.ExitCode -ne 0) { Write-Output ("  [FAIL] build A: built artifact exited " + $pe.ExitCode + " standalone (corrupt/unrunnable)"); $bldOk = $false }
}
Remove-Item -Recurse -Force $bA -ErrorAction SilentlyContinue
# (B) semantic-error source -> exit 1 + native diag + stdout clean + no raw leak + no artifact
$bB = Join-Path $root ".zig-cache/bldB_guard"
if (Test-Path $bB) { Remove-Item -Recurse -Force $bB }
New-Item -ItemType Directory -Force -Path (Join-Path $bB "src") | Out-Null
$bJia = Native 0x7532
$bZi = Native 0x5B57,0x8282
$bSrcB = @"
$N_const ${bJia}: $bZi = 300;

$N_pub $N_fn $N_main() $N_void {
    _ = ${bJia};
}
"@
[System.IO.File]::WriteAllText((Join-Path $bB "src/main.zz"), $bSrcB, $encNoBom)
$bBo = Join-Path $bB "b.out"; $bBe = Join-Path $bB "b.err"
$bpB = Start-Process -FilePath $zzc -ArgumentList "build" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $bB -RedirectStandardOutput $bBo -RedirectStandardError $bBe
$tbBo = Read-T $bBo; $tbBe = Read-T $bBe
if ($bpB.ExitCode -ne 1) { Write-Output ("  [FAIL] build B: semantic error expected exit 1 (not 0=CI-misjudge, not 2=usage), got " + $bpB.ExitCode); $bldOk = $false }
if (-not $tbBe.Contains($N_cuowu)) { Write-Output "  [FAIL] build B: native 'cuo-wu' diagnostic missing from stderr"; $bldOk = $false }
if ($tbBo.Trim().Length -ne 0) { Write-Output "  [FAIL] build B: failure leaked text to stdout (hint must be stderr-only)"; $bldOk = $false }
if ($tbBe.Contains("error: Failed") -or $tbBo.Contains("error: Failed")) { Write-Output "  [FAIL] build B: raw error name / stack trace leaked (silent bail shape required)"; $bldOk = $false }
if (Test-Path (((Join-Path $bB ".zzc/bin/main") + $ext))) { Write-Output "  [FAIL] build B: artifact emitted despite compile failure"; $bldOk = $false }
Remove-Item -Recurse -Force $bB -ErrorAction SilentlyContinue
if ($bldOk) { Write-Output "  [PASS] build guard: clean build exits 0 with native artifact hint and runnable exe; failed build exits 1 with native diag only, no raw error-name leak, no artifact" }
else { $fail = $fail + 1 }

# --- version self-report / manifest consistency guard (round 134): `zzc version`
# prints main.zig's `version_str` (main.zig is OUTSIDE the unit-test graph) while the
# package manifest build.zig.zon declares its own `.version`. These are two independent
# hardcoded copies of the same truth; a release that bumps one and forgets the other makes
# `zzc version` lie about the running build (CI/release tooling reads the wrong number).
# No unit test ties them and dispatch D only pins version non-empty -- so pin the value.
# Sabotage L32 version_str -> runtime token != manifest -> this guard fails while the test
# graph stays green (regression invisible to unit tests).
Write-Output "== version manifest-consistency guard =="
$vOk = $true
$zonRaw = [System.IO.File]::ReadAllText((Join-Path $root "build.zig.zon"), [System.Text.Encoding]::UTF8)
$zonM = [regex]::Match($zonRaw, '\.version\s*=\s*"([^"]+)"')
if (-not $zonM.Success) { Write-Output "  [FAIL] version guard: could not parse .version from build.zig.zon"; $vOk = $false }
$vo = Join-Path $root ".zig-cache/vg.out"; $ve = Join-Path $root ".zig-cache/vg.err"
$pv = Start-Process -FilePath $zzc -ArgumentList "version" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $vo -RedirectStandardError $ve
$vOut = Read-T $vo; $vErr = Read-T $ve
if ($pv.ExitCode -ne 0) { Write-Output ("  [FAIL] version guard: 'zzc version' expected exit 0, got " + $pv.ExitCode); $vOk = $false }
if ($vErr.Trim().Length -ne 0) { Write-Output "  [FAIL] version guard: 'zzc version' leaked text to stderr (info must be stdout-only)"; $vOk = $false }
$runM = [regex]::Match($vOut, '\d+\.\d+\.\d+')
if (-not $runM.Success) { Write-Output ("  [FAIL] version guard: 'zzc version' stdout carries no version token: [" + $vOut.Trim() + "]"); $vOk = $false }
elseif ($zonM.Success -and $runM.Value -ne $zonM.Groups[1].Value) { Write-Output ("  [FAIL] version guard: self-reported version '" + $runM.Value + "' != build.zig.zon .version '" + $zonM.Groups[1].Value + "' (drift -- 'zzc version' lies)"); $vOk = $false }
Remove-Item -Force $vo, $ve -ErrorAction SilentlyContinue
if ($vOk) { Write-Output "  [PASS] version guard: 'zzc version' exits 0, stdout-only, and self-reports exactly the build.zig.zon .version" }
else { $fail = $fail + 1 }

# --- `zzc test` success-path contract guard (round 135): cmdBuild's `.test_` branch (main.zig
# L564 zig-test step, L566 suppress -femit-bin, L579 native "zig test tong-guo(passed)" hint) is a DISTINCT
# exit-contract surface that never enters the unit-test graph. The build guard (round 132) pins
# only `.build`/`.run`; no existing guard ever invokes `zzc test`. Probe-confirmed real behavior:
# clean dialect project -> `zzc test` exit 0 + stdout exactly "\u2714 zig test \u901a\u8fc7" + NO .zzc/bin artifact.
# A semantic-error source is deliberately NOT a fail-form here: `zig test` lazy-analyzes and prunes
# the unreferenced decls, so an error project passes VACUOUSLY (exit 0) -- asserting exit 1 would be
# a fabricated pin, honestly excluded. Sabotage L579 hint -> success message missing -> only this
# guard turns red while the 187-test graph stays green (regression invisible to unit tests).
Write-Output "== test success-path contract guard =="
$tOk = $true
$N_tongguo = Native 0x901A,0x8FC7             # tong-guo (passed), native test success hint
$tA = Join-Path $root ".zig-cache/tstA_guard"
if (Test-Path $tA) { Remove-Item -Recurse -Force $tA }
New-Item -ItemType Directory -Force -Path (Join-Path $tA "src") | Out-Null
$tSrcA = @"
$N_const std = $N_import("std");

$N_pub $N_fn $N_main() $N_void {
    std.debug.print("ok135", .{});
}
"@
[System.IO.File]::WriteAllText((Join-Path $tA "src/main.zz"), $tSrcA, $encNoBom)
$toA = Join-Path $tA "a.out"; $teA = Join-Path $tA "a.err"
$tpA = Start-Process -FilePath $zzc -ArgumentList "test" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $tA -RedirectStandardOutput $toA -RedirectStandardError $teA
$tpAo = Read-T $toA; $tpAe = Read-T $teA
if ($tpA.ExitCode -ne 0) { Write-Output ("  [FAIL] test A: clean 'zzc test' expected exit 0, got " + $tpA.ExitCode); $tOk = $false }
if (-not $tpAo.Contains($N_tongguo)) { Write-Output "  [FAIL] test A: native 'tong-guo' success hint missing from stdout (.test_ hint dropped)"; $tOk = $false }
if ($tpAo.Contains($N_chanhao)) { Write-Output "  [FAIL] test A: stdout carries 'chan-wu' artifact hint -- .test_ branch conflated with .build"; $tOk = $false }
if ($tpAe.Trim().Length -ne 0) { Write-Output "  [FAIL] test A: 'zzc test' leaked text to stderr (success hint must be stdout-only)"; $tOk = $false }
if (Test-Path (((Join-Path $tA ".zzc/bin/main") + $ext))) { Write-Output "  [FAIL] test A: 'zzc test' emitted a binary artifact (no-emit-bin contract broken)"; $tOk = $false }
Remove-Item -Recurse -Force $tA -ErrorAction SilentlyContinue
if ($tOk) { Write-Output "  [PASS] test guard: clean 'zzc test' exits 0 with native 'zig test passed' hint on stdout, no 'artifact' conflation, no stderr leak, emits no binary" }
else { $fail = $fail + 1 }

# --- `zzc check` success-path contract guard (round 136): cmdCheck ends with the zzc-owned
# native hint "jian-ch-a tong-guo: N fang-yan wen-jian ..." (main.zig L531); main.zig is OUTSIDE
# the unit-test graph. The demos loop already exits-0-checks `zzc check` per demo (that catch
# covers the multi-file build-exe-shape regression only); NO guard ever asserts the success
# MESSAGE itself -- deleting L531 would be caught nowhere else. The fail path (exit 1 + native
# diag + stdout-clean + no 'error: Failed') is already pinned by the build guard B (round 132,
# same collect/translate/zigCompile chain) -- not re-pinned here. Sabotage L531 -> hint gone ->
# only this guard turns red while the 187-test graph stays green.
Write-Output "== check success-path contract guard =="
$kOk = $true
$N_fangyanwenjian = Native 0x65B9,0x8A00,0x6587,0x4EF6   # fang-yan wen-jian (dialect files), part of the check hint
$kA = Join-Path $root ".zig-cache/chkA_guard"
if (Test-Path $kA) { Remove-Item -Recurse -Force $kA }
New-Item -ItemType Directory -Force -Path (Join-Path $kA "src") | Out-Null
$kSrcMain = @"
$N_const std = $N_import("std");

$N_pub $N_fn $N_main() $N_void {
    $N_const lib = $N_import("lib.zz");
    std.debug.print("{d}", .{lib.$N_dezhi()});
}
"@
$kSrcLib = @"
$N_pub $N_fn $N_dezhi() $N_int32 {
    $N_ret 136;
}
"@
[System.IO.File]::WriteAllText((Join-Path $kA "src/main.zz"), $kSrcMain, $encNoBom)
[System.IO.File]::WriteAllText((Join-Path $kA "src/lib.zz"), $kSrcLib, $encNoBom)
$koA = Join-Path $kA "k.out"; $keA = Join-Path $kA "k.err"
$kpA = Start-Process -FilePath $zzc -ArgumentList "check" -NoNewWindow -Wait -PassThru `
    -WorkingDirectory $kA -RedirectStandardOutput $koA -RedirectStandardError $keA
$koAt = Read-T $koA; $keAt = Read-T $keA
if ($kpA.ExitCode -ne 0) { Write-Output ("  [FAIL] check A: clean 'zzc check' expected exit 0, got " + $kpA.ExitCode); $kOk = $false }
if (-not $koAt.Contains($N_tongguo)) { Write-Output "  [FAIL] check A: native 'tong-guo' success hint missing from stdout (cmdCheck L531 hint dropped)"; $kOk = $false }
if (-not $koAt.Contains($N_fangyanwenjian)) { Write-Output "  [FAIL] check A: hint lacks 'fang-yan wen-jian' phrasing (message degraded)"; $kOk = $false }
if ($keAt.Trim().Length -ne 0) { Write-Output "  [FAIL] check A: 'zzc check' leaked text to stderr (success hint must be stdout-only)"; $kOk = $false }
Remove-Item -Recurse -Force $kA -ErrorAction SilentlyContinue
if ($kOk) { Write-Output "  [PASS] check guard: clean two-file project 'zzc check' exits 0 with native success hint on stdout, no stderr leak" }
else { $fail = $fail + 1 }

# --- `zzc lang` info-line consistency guard (round 136): the detail line prints Pack fields
# (main.zig L972, OUTSIDE the unit-test graph) whose truth source is the pack file itself
# ($name/$code in src/lang/packs/Chinese.txt) -- the SAME display/manifest dual-copy pattern the
# version guard (round 134) pinned for version_str vs build.zig.zon. Drift here makes `zzc lang`
# lie about the loaded pack (user picks a name that does not exist). Also asserts the native
# section headers exist (dropping the registerable-pack list would leave users without action).
Write-Output "== lang info-consistency guard =="
$lOk = $true
$N_zhongwen = Native 0x4E2D,0x6587                     # zhong-wen: pack filename stem AND default $name value
$N_dangqian = Native 0x5F53,0x524D,0x8BED,0x8A00,0x5305 # dang-qian yu-yan-bao (current language pack)
$N_kezhuce = Native 0x53EF,0x6CE8,0x518C,0x5305         # ke-zhu-ce-bao (registerable packs)
$colonF = [string][char]0xFF1A                          # fullwidth colon used by the detail line
$packPath = Join-Path $root ("src/lang/packs/" + $N_zhongwen + ".txt")
$packRaw = [System.IO.File]::ReadAllText($packPath, [System.Text.Encoding]::UTF8)
$mName = [regex]::Match($packRaw, '(?m)^\$name\s*=\s*(.+?)\s*$')
$mCode = [regex]::Match($packRaw, '(?m)^\$code\s*=\s*(.+?)\s*$')
if (-not $mName.Success) { Write-Output "  [FAIL] lang guard: could not parse \$name from the embedded pack"; $lOk = $false }
if (-not $mCode.Success) { Write-Output "  [FAIL] lang guard: could not parse \$code from the embedded pack"; $lOk = $false }
$lo = Join-Path $root ".zig-cache/lgd.out"; $le = Join-Path $root ".zig-cache/lgd.err"
$pl = Start-Process -FilePath $zzc -ArgumentList "lang" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $lo -RedirectStandardError $le
$loT = Read-T $lo; $leT = Read-T $le
if ($pl.ExitCode -ne 0) { Write-Output ("  [FAIL] lang guard: 'zzc lang' expected exit 0, got " + $pl.ExitCode); $lOk = $false }
if ($leT.Trim().Length -ne 0) { Write-Output "  [FAIL] lang guard: 'zzc lang' leaked text to stderr (info must be stdout-only)"; $lOk = $false }
if (-not $loT.Contains($N_dangqian)) { Write-Output "  [FAIL] lang guard: native 'dang-qian yu-yan-bao' detail header missing"; $lOk = $false }
if (-not $loT.Contains($N_kezhuce)) { Write-Output "  [FAIL] lang guard: native 'ke-zhu-ce-bao' registerable-list header missing (users left without action)"; $lOk = $false }
if ($mName.Success) {
    $shown = [regex]::Match($loT, [regex]::Escape($N_dangqian + $colonF) + '(.+?)\(').Groups[1].Value
    if ($shown -ne $mName.Groups[1].Value) { Write-Output ("  [FAIL] lang guard: displayed pack name '" + $shown + "' != pack \$name '" + $mName.Groups[1].Value + "' (drift -- 'zzc lang' lies)"); $lOk = $false }
}
if ($mCode.Success) {
    $shownCode = [regex]::Match($loT, [regex]::Escape($N_dangqian + $colonF) + '.+?\(([^)]*)\)').Groups[1].Value
    if ($shownCode -ne $mCode.Groups[1].Value) { Write-Output ("  [FAIL] lang guard: displayed pack code '" + $shownCode + "' != pack \$code '" + $mCode.Groups[1].Value + "'"); $lOk = $false }
    $after = $loT.Substring($loT.IndexOf($N_kezhuce) + $N_kezhuce.Length)
    if (-not $after.Contains($mCode.Groups[1].Value + "(")) { Write-Output ("  [FAIL] lang guard: registerable list omits key '" + $mCode.Groups[1].Value + "' (list empty or degraded)"); $lOk = $false }
}
Remove-Item -Force $lo, $le -ErrorAction SilentlyContinue
if ($lOk) { Write-Output "  [PASS] lang guard: 'zzc lang' exits 0, stdout-only, detail name/code match the embedded pack, registerable list carries the default key" }
else { $fail = $fail + 1 }

# --- `--lang` builtin-pack selection e2e guard (round 137): the flag chain lives in
# main.zig L914-942 (OUTSIDE the unit-test graph). The r9g section pins --lang-file shapes
# and the --lang x --lang-file mutual exclusion only; NO guard ever invokes a standalone
# `--lang`. Three unpinned faces: (A) a valid builtin key selects the pack and the version
# line reflects it (findLangFlag hit + registry.lookup success); (B) an unknown pack name
# exits 2 with the native 'wei-zhi yu-yan-bao' hint and a clean stdout (L926-933 orelse
# branch - its only exit-code responsibility); (C) the flag pair is stripped before the
# command runs (stripLangFlag) -- if a regression leaked '--lang' into argv it would reach
# zig as an unknown argument and break a real check, while A/B would stay green because
# `version` never consumes argv. Script stays pure ASCII; native strings from code points.
Write-Output "== lang flag selection guard =="
$gOk = $true
$N_yuyanbao = Native 0x8BED,0x8A00,0x5305              # yu-yan-bao (language pack), shown by the version line
$N_weizhiyuyanbao = Native 0x672A,0x77E5,0x8BED,0x8A00,0x5305 # wei-zhi yu-yan-bao (unknown language pack), stderr hint
# A: --lang zh positive selection on `version`
$goA = Join-Path $root ".zig-cache/gfA.out"; $geA = Join-Path $root ".zig-cache/gfA.err"
$gpA = Start-Process -FilePath $zzc -ArgumentList @("version", "--lang", "zh") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $goA -RedirectStandardError $geA
$goAt = Read-T $goA; $geAt = Read-T $geA
if ($gpA.ExitCode -ne 0) { Write-Output ("  [FAIL] flag A: 'zzc version --lang zh' expected exit 0, got " + $gpA.ExitCode); $gOk = $false }
if (-not $goAt.Contains($N_yuyanbao)) { Write-Output "  [FAIL] flag A: version line lacks the 'yu-yan-bao' pack echo (selection result not reported)"; $gOk = $false }
if (-not $goAt.Contains($N_zhongwen)) { Write-Output "  [FAIL] flag A: selected pack name 'zhong-wen' not echoed (lookup hit not reflected)"; $gOk = $false }
if ($geAt.Trim().Length -ne 0) { Write-Output "  [FAIL] flag A: 'version --lang zh' leaked text to stderr (info must be stdout-only)"; $gOk = $false }
Remove-Item -Force $goA, $geA -ErrorAction SilentlyContinue
# B: unknown pack name -> exit 2 + native hint on stderr + stdout clean
$goB = Join-Path $root ".zig-cache/gfB.out"; $geB = Join-Path $root ".zig-cache/gfB.err"
$gpB = Start-Process -FilePath $zzc -ArgumentList @("version", "--lang", "klingon") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $goB -RedirectStandardError $geB
$goBt = Read-T $goB; $geBt = Read-T $geB
if ($gpB.ExitCode -ne 2) { Write-Output ("  [FAIL] flag B: unknown pack expected exit 2 (usage-error class), got " + $gpB.ExitCode); $gOk = $false }
if (-not $geBt.Contains($N_weizhiyuyanbao)) { Write-Output "  [FAIL] flag B: native 'wei-zhi yu-yan-bao' hint missing from stderr"; $gOk = $false }
if ($goBt.Trim().Length -ne 0) { Write-Output "  [FAIL] flag B: unknown-pack error leaked text to stdout (hint must be stderr-only)"; $gOk = $false }
Remove-Item -Force $goB, $geB -ErrorAction SilentlyContinue
# C: flag stripped from argv -- the true consumer is cmdBuild: main.zig L571-574 forwards
# every leftover zig_arg to `zig build-exe`, while pickEntry only matches `.zz` suffixes, so
# a leaked '--lang zh' pair would reach zig as unknown arguments and break the build. A
# `check` shape CANNOT defend this (cmdCheck never forwards argv -- S2 round 137 measured
# the leak passing every check assertion), hence the build form: demo/hello with --lang zh
# must exit 0 with the native artifact hint; a leak exits 1 with zig's error on stderr.
$goC = Join-Path $root ".zig-cache/gfC.out"; $geC = Join-Path $root ".zig-cache/gfC.err"
$gpC = Start-Process -FilePath $zzc -ArgumentList @("build", "--lang", "zh", "src/main.zz") -NoNewWindow -Wait -PassThru -WorkingDirectory (Join-Path $root "demo/hello") -RedirectStandardOutput $goC -RedirectStandardError $geC
$goCt = Read-T $goC; $geCt = Read-T $geC
if ($gpC.ExitCode -ne 0) { Write-Output ("  [FAIL] flag C: 'zzc build --lang zh' on demo/hello expected exit 0 (flag must be stripped before argv reaches zig), got " + $gpC.ExitCode); $gOk = $false }
if (-not $goCt.Contains($N_chanhao)) { Write-Output "  [FAIL] flag C: build hint 'chan-hao' missing -- --lang form silently degraded the build"; $gOk = $false }
if ($geCt.Trim().Length -ne 0) { Write-Output "  [FAIL] flag C: leaked text to stderr on the --lang build path (zig got raw '--lang'?)"; $gOk = $false }
Remove-Item -Force $goC, $geC -ErrorAction SilentlyContinue
if ($gOk) { Write-Output "  [PASS] flag guard: --lang zh selects+echoes the pack, unknown names exit 2 with native hint (stdout clean), and the flag is stripped before argv reaches zig" }
else { $fail = $fail + 1 }

# --- EOL truth-source guard (round 139, user decision #3): the fmt gate above only proves
# the CURRENT working tree is LF; it cannot see the declaration that KEEPS it LF. Measured
# A/B on fresh clones (system core.autocrlf=true, the default Windows contributor/runner
# shape): without .gitattributes every tracked .zig/.zon checks out CRLF and the repo-wide
# fmt gate turns red on all 15 files with zero code changes; with it, checkout is LF and
# the gate is green. So the declaration is load-bearing for every green gate elsewhere in
# this script, yet it lives outside the unit-test graph and nothing pinned its existence.
# Second assert pins the round-139 boundary: `.zz` is deliberately NOT normalized because
# input EOL is observable (a CRLF dialect source keeps a trailing CR inside the rendered
# source-line snippet of diagnostics, an LF one does not -- byte-diffed this round), so
# normalizing it would silently refresh demo snapshots = a behavior change, own round only.
Write-Output "== eol truth-source guard =="
$eOk = $true
$gaPath = Join-Path $root ".gitattributes"
if (-not (Test-Path $gaPath)) {
    Write-Output "  [FAIL] eol guard: .gitattributes missing -- the repo-level EOL declaration that keeps a fresh CRLF-defaulting clone out of the fmt gate was dropped"
    $eOk = $false
} else {
    $gaTxt = [System.IO.File]::ReadAllText($gaPath)
    if ($gaTxt -match '(?m)^\*\.zz\b') { Write-Output "  [FAIL] eol guard: .zz is now normalized by .gitattributes -- input EOL is observable in diagnostics and demo snapshots; this must be decided as its own round, not smuggled in"; $eOk = $false }
}
$rows = @(git ls-files --eol 2>$null | Where-Object { $_ -match '\.(zig|zon)$' })
if ($rows.Count -eq 0) {
    Write-Output "  [FAIL] eol guard: 'git ls-files --eol' yielded no .zig/.zon rows (git unavailable or repo shape changed -- this guard would idle silently)"
    $eOk = $false
}
foreach ($r in $rows) {
    if ($r -notmatch 'eol=lf') { Write-Output ("  [FAIL] eol guard: tracked source not pinned to LF checkout: " + $r); $eOk = $false }
}
if ($eOk) { Write-Output ("  [PASS] eol guard: repo-level EOL declaration present, all " + $rows.Count + " tracked .zig/.zon pinned to LF, dialect sources left EOL-transparent as measured") }
else { $fail = $fail + 1 }

# --- `zzc lang add` install + runtime-selection e2e guard (round 140, user-delegated
# design). Measured this round on a fresh tree: dropping a pack into src/lang/packs does
# NOT rerun build.zig's scan step (R9f/D45 -- stale cache hides it; only swapping the
# cache-dir makes it appear), so any "write packs + recompile hint" design would ship a
# lie. The shipped design installs into the project-level .zzc/lang/<key>.txt and the
# --lang selector falls back to it at RUNTIME. Unit tests (userpack.zig) cover keyIsSafe/
# install/installedFile with real IO, but the two pieces living in main.zig -- the
# selector fallback and the verb dispatch (including the round-136 pinned bare `zzc lang`
# shape staying byte-identical, and unknown verbs now exiting 2 where old code silently
# ignored extra argv) -- are OUTSIDE the unit-test graph and only this e2e section can
# catch their regression. Fixture: tools/fixtures/external-min.txt ($code = tst-ja).
Write-Output "== lang add install guard =="
$laOk = $true
$lp = Join-Path $root ".zig-cache/guard_langadd_140"
function Run-LA([string[]]$cmdArgs) {
    $o = Join-Path $root ".zig-cache/la.out"; $e = Join-Path $root ".zig-cache/la.err"
    $p = Start-Process -FilePath $zzc -ArgumentList $cmdArgs -NoNewWindow -Wait -PassThru -WorkingDirectory $lp -RedirectStandardOutput $o -RedirectStandardError $e
    $t = Read-T $o; $r = Read-T $e
    Remove-Item -Force $o, $e -ErrorAction SilentlyContinue
    return @($p.ExitCode, $t, $r)
}
if (Test-Path $lp) { Remove-Item -Recurse -Force $lp }
New-Item -ItemType Directory -Force $lp | Out-Null
$fxm = Join-Path $root "tools/fixtures/external-min.txt"
$N_azhuang = Native 0x5DF2,0x88C5,0x5165     # yi-zhuang-ru ("installed"), success marker
$N_bukeyong = Native 0x6CE8,0x518C,0x540D,0x300C # zhu-ce-ming + open bracket (unsafe-key rejection marker; "bu-ke-yong" follows the quoted key, not the bracket)
$N_yizhuang = Native 0x672C,0x5DE5,0x7A0B,0x5185,0x5DF2,0x88C5,0x6709 # ben-gong-cheng-nei-yi-zhuang-you (dup rejection marker)
$installed = Join-Path $lp ".zzc/lang/g140x.txt"
# A: add --as g140x -> exit 0, file lands byte-identical, success line on stdout
$res = Run-LA @("lang", "add", $fxm, "--as", "g140x")
if ($res[0] -ne 0) { Write-Output ("  [FAIL] langadd A: 'lang add --as g140x' expected exit 0, got " + $res[0] + " stderr: " + $res[2].Trim()); $laOk = $false }
if (-not $res[1].Contains($N_azhuang)) { Write-Output "  [FAIL] langadd A: success line 'yi-zhuang-ru' missing from stdout"; $laOk = $false }
if (-not (Test-Path $installed)) { Write-Output "  [FAIL] langadd A: .zzc/lang/g140x.txt not written into the project"; $laOk = $false }
else {
    if (-not (Same-Bytes ([System.IO.File]::ReadAllBytes($fxm)) ([System.IO.File]::ReadAllBytes($installed)))) { Write-Output "  [FAIL] langadd A: installed bytes differ from the fixture (pack body was altered on install)"; $laOk = $false }
}
# B: --lang g140x selects it at RUNTIME -- no recompile happened nor is needed
$res = Run-LA @("version", "--lang", "g140x")
if ($res[0] -ne 0) { Write-Output ("  [FAIL] langadd B: 'version --lang g140x' on a runtime-installed pack expected exit 0 (selection fallback dropped), got " + $res[0] + " stderr: " + $res[2].Trim()); $laOk = $false }
if ($res[1].Trim().Length -eq 0) { Write-Output "  [FAIL] langadd B: version printed nothing -- fallback matched nothing"; $laOk = $false }
# C: duplicate add -> exit 2, original bytes untouched (anti-overwrite contract)
$before = [System.IO.File]::ReadAllBytes($installed)
$res = Run-LA @("lang", "add", $fxm, "--as", "g140x")
if ($res[0] -ne 2) { Write-Output ("  [FAIL] langadd C: duplicate add expected exit 2, got " + $res[0]); $laOk = $false }
if (-not $res[2].Contains($N_yizhuang)) { Write-Output "  [FAIL] langadd C: dup rejection missing 'ben-gong-cheng-nei-yi-zhuang-you' hint on stderr"; $laOk = $false }
if (-not (Same-Bytes $before ([System.IO.File]::ReadAllBytes($installed)))) { Write-Output "  [FAIL] langadd C: rejected duplicate still altered the installed file"; $laOk = $false }
# D: invalid pack -> exit 1 and NOTHING written (validate gate precedes any IO side-effect)
$res = Run-LA @("lang", "add", (Join-Path $root "tools/fixtures/external-partial.txt"), "--as", "g140d")
if ($res[0] -ne 1) { Write-Output ("  [FAIL] langadd D: bad pack expected exit 1 (contract hard gate), got " + $res[0]); $laOk = $false }
if (Test-Path (Join-Path $lp ".zzc/lang/g140d.txt")) { Write-Output "  [FAIL] langadd D: rejected bad pack still left a file behind"; $laOk = $false }
# E: path-escape --as -> exit 2, nothing written outside the project lang dir
$res = Run-LA @("lang", "add", $fxm, "--as", "../evil140")
if ($res[0] -ne 2) { Write-Output ("  [FAIL] langadd E: '--as ../evil140' expected exit 2 (key whitelist), got " + $res[0]); $laOk = $false }
if (-not $res[2].Contains($N_bukeyong)) { Write-Output "  [FAIL] langadd E: unsafe-key rejection missing native 'zhu-ce-ming bu-ke-yong' hint"; $laOk = $false }
if (Test-Path (Join-Path $lp ".zzc/lang/evil140.txt")) { Write-Output "  [FAIL] langadd E: traversal key escaped the whitelist and wrote next to it"; $laOk = $false }
# F: unknown verb -> exit 2 + clean stdout (OLD behavior measured this round: extra argv
# was wholly ignored, `zzc lang add x.txt` printed the detail block and exited 0 -- a lie)
$res = Run-LA @("lang", "unknowverb140")
if ($res[0] -ne 2) { Write-Output ("  [FAIL] langadd F: unknown verb expected exit 2 (the round-140 verb seal), got " + $res[0]); $laOk = $false }
if ($res[1].Trim().Length -ne 0) { Write-Output "  [FAIL] langadd F: unknown verb leaked text to stdout (old buggy shape printed info+exit 0?)"; $laOk = $false }
# G: bare `zzc lang` unchanged -> exit 0 + clean stderr (136-pinned shape must survive verb dispatch)
$res = Run-LA @("lang")
if ($res[0] -ne 0) { Write-Output ("  [FAIL] langadd G: bare 'zzc lang' expected exit 0, got " + $res[0]); $laOk = $false }
if ($res[2].Trim().Length -ne 0) { Write-Output "  [FAIL] langadd G: bare 'zzc lang' leaked to stderr after the verb-dispatch refactor"; $laOk = $false }
Remove-Item -Recurse -Force $lp -ErrorAction SilentlyContinue
if ($laOk) { Write-Output "  [PASS] lang add guard: install byte-exact, runtime --lang selection without recompile, dup->2/bytes kept, bad pack->1/zero writes, traversal->2, unknown verb->2 (stdout clean), bare lang shape preserved" }
else { $fail = $fail + 1 }

# --- zzc lsp LSP handshake e2e guard (round 156). Framing and dispatch cores are
# unit-tested in-graph, but the stdin/stdout assembly in main.zig is OUTSIDE the
# test graph -- only this e2e section can catch wiring regressions (buffer drain,
# flush-per-response, EOF exit, exit-notification stop). Script stays pure ASCII:
# native word forms enter JSON via \uXXXX escapes; asserts decode UTF-8 off the
# wire (round-133/D52 cross-platform discipline: forward slashes, no PS 5.1-only
# constructs, no node dependency -- .NET streams drive the whole handshake).
Write-Output "== lsp handshake guard =="
$lspOk = $true
$acc = New-Object Collections.Generic.List[byte]
function Add-Frame([string]$body) {
    $b = [Text.Encoding]::UTF8.GetBytes($body)
    $h = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($b.Length)`r`n`r`n")
    foreach ($x in $h) { $acc.Add($x) }
    foreach ($x in $b) { $acc.Add($x) }
}
# initialize(id1) -> initialized -> didOpen(chang-shu a = 1 + fullwidth comma) ->
# hover(id2 at line0 char0 on chang-shu) -> shutdown(id3) -> exit. The dialect
# word and the fullwidth comma ride in as \uXXXX escapes (script stays ASCII).
Add-Frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
Add-Frame '{"jsonrpc":"2.0","method":"initialized","params":{}}'
Add-Frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///g156.zz","languageId":"zig-dialect","version":1,"text":"\u5E38\u6570 a = 1\uFF0C\n"}}}'
Add-Frame '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///g156.zz"},"position":{"line":0,"character":0}}}'
# semanticTokens/full on the same doc: "\u5E38\u6570 a = 1\uFF0C" -> 常数 keyword(0) then a
# standalone ASCII letter (skipped) and the fullwidth comma (no token) -> exactly one tuple [0,0,2,0,0].
Add-Frame '{"jsonrpc":"2.0","id":4,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///g156.zz"}}}'
Add-Frame '{"jsonrpc":"2.0","id":3,"method":"shutdown"}'
Add-Frame '{"jsonrpc":"2.0","method":"exit"}'
$li = Join-Path $root ".zig-cache/lsp156.in"; $lo = Join-Path $root ".zig-cache/lsp156.out"; $le = Join-Path $root ".zig-cache/lsp156.err"
[IO.File]::WriteAllBytes($li, $acc.ToArray())
$proc = Start-Process -FilePath $zzc -ArgumentList "lsp" -NoNewWindow -Wait -PassThru `
    -RedirectStandardInput $li -RedirectStandardOutput $lo -RedirectStandardError $le
$raw = Read-B $lo
if ($raw.Count -eq 0) { $raw = [byte[]]::new(0) }
$ltxt = [Text.Encoding]::UTF8.GetString([byte[]]$raw)
$errb = Read-B $le
if ($errb.Count -eq 0) { $errb = [byte[]]::new(0) }
$leString = [Text.Encoding]::UTF8.GetString([byte[]]$errb)
Remove-Item -Force $li, $lo, $le -ErrorAction SilentlyContinue
if ($proc.ExitCode -ne 0) { Write-Output ("  [FAIL] lsp: handshake run exited " + $proc.ExitCode + " (expected 0)"); $lspOk = $false }
if ($leString.Trim().Length -ne 0) { Write-Output ("  [FAIL] lsp: human text leaked to stderr: " + $leString.Trim()); $lspOk = $false }
$msgs = @([regex]::Split($ltxt, "Content-Length:\s*\d+`r`n`r`n") | Where-Object { $_.Trim().Length -gt 0 })
if ($msgs.Count -ne 5) { Write-Output ("  [FAIL] lsp: expected exactly 5 framed messages, got " + $msgs.Count); $lspOk = $false }
if ($lspOk) {
    $N_cifa = Native 0x8BCD,0x6CD5        # ci-fa (lexical diagnostics kind)
    $N_gjz  = Native 0x5173,0x952E,0x5B57 # guan-jian-zi (hover group label)
    if (-not ($msgs[0].Contains('"id":1') -and $msgs[0].Contains('"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}}') -and $msgs[0].Contains('"hoverProvider":true') -and $msgs[0].Contains('"semanticTokensProvider"') -and $msgs[0].Contains('"documentSymbolProvider":true') -and $msgs[0].Contains('"definitionProvider":true') -and $msgs[0].Contains('"referencesProvider":true') -and $msgs[0].Contains('"documentHighlightProvider":true') -and $msgs[0].Contains('"codeActionProvider":true') -and $msgs[0].Contains('"foldingRangeProvider":true') -and $msgs[0].Contains('"renameProvider":{"prepareProvider":true}') -and $msgs[0].Contains('"workspaceSymbolProvider":true') -and $msgs[0].Contains('"signatureHelpProvider":{"triggerCharacters":["(",","]}') -and $msgs[0].Contains('"selectionRangeProvider":true'))) { Write-Output "  [FAIL] lsp: initialize reply lost id/capabilities (save-object sync form / semanticTokensProvider / documentSymbolProvider / definitionProvider / referencesProvider / documentHighlightProvider / codeActionProvider / foldingRangeProvider / renameProvider{prepareProvider} / workspaceSymbolProvider / signatureHelpProvider / selectionRangeProvider)"; $lspOk = $false }
    if (-not ($msgs[1].Contains('publishDiagnostics') -and $msgs[1].Contains('file:///g156.zz') -and $msgs[1].Contains($N_cifa))) { Write-Output "  [FAIL] lsp: didOpen did not publish native-lexical diagnostics for the fullwidth comma"; $lspOk = $false }
    if (-not ($msgs[2].Contains('"id":2') -and $msgs[2].Contains('const') -and $msgs[2].Contains($N_gjz))) { Write-Output "  [FAIL] lsp: hover on chang-shu did not resolve to const/keyword-group"; $lspOk = $false }
    if (-not ($msgs[3].Contains('"id":4') -and $msgs[3].Contains('"data":[0,0,2,0,0') -and -not $msgs[3].Contains('"data":[]'))) { Write-Output "  [FAIL] lsp: semanticTokens/full did not return the chang-shu keyword tuple [0,0,2,0,0]"; $lspOk = $false }
    if (-not ($msgs[4].Contains('"id":3') -and $msgs[4].Contains('"result":null'))) { Write-Output "  [FAIL] lsp: shutdown reply not result-null"; $lspOk = $false }
    # framing self-consistency: every declared Content-Length must match its body bytes
    $pos = 0
    while ($pos -lt $raw.Length) {
        $hdrEnd = -1
        for ($j = $pos; $j -lt $raw.Length - 3; $j++) { if ($raw[$j] -eq 13 -and $raw[$j+1] -eq 10 -and $raw[$j+2] -eq 13 -and $raw[$j+3] -eq 10) { $hdrEnd = $j; break } }
        if ($hdrEnd -lt 0) { Write-Output "  [FAIL] lsp: output stream is not frame-parseable (missing header terminator)"; $lspOk = $false; break }
        $hdr = [Text.Encoding]::ASCII.GetString($raw[$pos..($hdrEnd - 1)])
        $cm = [regex]::Match($hdr, "Content-Length:\s*(\d+)")
        if (-not $cm.Success) { Write-Output "  [FAIL] lsp: frame header lacks Content-Length"; $lspOk = $false; break }
        $clen = [int]$cm.Groups[1].Value
        $bstart = $hdrEnd + 4
        if ($bstart + $clen -gt $raw.Length) { Write-Output "  [FAIL] lsp: Content-Length overruns the stream"; $lspOk = $false; break }
        $pos = $bstart + $clen
    }
    if ($lspOk -and $pos -ne $raw.Length) { Write-Output "  [FAIL] lsp: trailing bytes after last frame"; $lspOk = $false }
}
if ($lspOk) { Write-Output "  [PASS] lsp guard: full handshake over real stdio -- init/didOpen-publish/hover/semanticTokens/shutdown/exit, 5 frames byte-consistent, stderr clean, exit 0" }
else { $fail = $fail + 1 }

# --- zzc lsp on-save SEMANTIC diagnostics e2e guard (round 159). didSave must trigger a
# real `zzc check --machine` child compile and publish back-translated native SEMANTIC
# diagnostics -- but ONLY on save, never on didOpen/didChange (per-keystroke compile is
# deliberately avoided: slow + races symbols.txt). Drives real `zzc lsp` over a throwaway
# project whose sole error (u8=300) passes the lexical + pure-native fast path (empty)
# yet fails zig compile -- so a semantic diagnostic appearing after didSave and NOT after
# didOpen is the load-bearing proof of save-gating + the check-machine reuse (message and
# .zz coordinates come verbatim from the already-tested --machine chain). didOpen carries
# empty text (fast path clean -> "[]"), which also keeps the frames ASCII; the semantic
# provider compiles the ON-DISK file, independent of the buffer text. Zig-gated (D52):
# without zig the child cannot start, produces no machine-diag line -> semantic-content
# asserts are [SKIP]-ed while the mechanism assert (didSave round-trips a publish) holds.
Write-Output "== lsp on-save semantic guard =="
$soOk = $true
$soDir = Join-Path $root ".zig-cache/lsp159_guard"
if (Test-Path $soDir) { Remove-Item -Recurse -Force $soDir }
New-Item -ItemType Directory -Force -Path (Join-Path $soDir "src") | Out-Null
# chang-shu jia: zi-jie = 300; (wu-fu/u8 out-of-range) + pub fn main() -> void
$soJia = Native 0x7532
$soZi  = Native 0x5B57,0x8282
$soSrc = @"
$N_const ${soJia}: $soZi = 300;

$N_pub $N_fn $N_main() $N_void {
    _ = ${soJia};
}
"@
$soFile = Join-Path $soDir "src/main.zz"
[System.IO.File]::WriteAllText($soFile, $soSrc, $encNoBom)
$soUri = "file:///" + ((Resolve-Path $soFile).Path -replace '\\','/')
$acc = New-Object Collections.Generic.List[byte]
Add-Frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
Add-Frame '{"jsonrpc":"2.0","method":"initialized","params":{}}'
Add-Frame ('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"' + $soUri + '","languageId":"zig-dialect","version":1,"text":""}}}')
Add-Frame ('{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"' + $soUri + '"}}}')
Add-Frame '{"jsonrpc":"2.0","id":3,"method":"shutdown"}'
Add-Frame '{"jsonrpc":"2.0","method":"exit"}'
$si = Join-Path $root ".zig-cache/lsp159.in"; $so = Join-Path $root ".zig-cache/lsp159.out"; $se = Join-Path $root ".zig-cache/lsp159.err"
[IO.File]::WriteAllBytes($si, $acc.ToArray())
$sp = Start-Process -FilePath $zzc -ArgumentList "lsp" -NoNewWindow -Wait -PassThru `
    -RedirectStandardInput $si -RedirectStandardOutput $so -RedirectStandardError $se
$rawSo = Read-B $so
if ($rawSo.Count -eq 0) { $rawSo = [byte[]]::new(0) }
$txtSo = [Text.Encoding]::UTF8.GetString([byte[]]$rawSo)
$errSo = Read-B $se
if ($errSo.Count -eq 0) { $errSo = [byte[]]::new(0) }
$strSoErr = [Text.Encoding]::UTF8.GetString([byte[]]$errSo)
Remove-Item -Force $si, $so, $se -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $soDir -ErrorAction SilentlyContinue
if ($sp.ExitCode -ne 0) { Write-Output ("  [FAIL] on-save: lsp run exited " + $sp.ExitCode + " (expected 0)"); $soOk = $false }
if ($strSoErr.Trim().Length -ne 0) { Write-Output ("  [FAIL] on-save: human text leaked to stderr: " + $strSoErr.Trim()); $soOk = $false }
$mso = @([regex]::Split($txtSo, "Content-Length:\s*\d+`r`n`r`n") | Where-Object { $_.Trim().Length -gt 0 })
if ($mso.Count -ne 4) { Write-Output ("  [FAIL] on-save: expected 4 framed messages (init/didOpen-publish/didSave-publish/shutdown), got " + $mso.Count); $soOk = $false }
if ($soOk) {
    # mechanism (zig-independent): didOpen and didSave each round-trip a publishDiagnostics
    if (-not ($mso[1].Contains('publishDiagnostics') -and $mso[2].Contains('publishDiagnostics'))) { Write-Output "  [FAIL] on-save: didOpen/didSave did not each publish diagnostics"; $soOk = $false }
    # didOpen must be FAST-ONLY clean (empty): the semantic error is save-gated, not keystroke-gated
    if (-not $mso[1].Contains('"diagnostics":[]')) { Write-Output "  [FAIL] on-save: didOpen leaked diagnostics - semantic must not run on open/change"; $soOk = $false }
    if (Get-Command zig -ErrorAction SilentlyContinue) {
        # The machine line is `<file>:<line>:<col>: <kind>: <msg>`; the parser routes <kind>
        # (cuo-wu = error) into LSP severity=1 (DiagnosticSeverity.Error) and keeps only <msg>
        # as the diagnostic message -- so the anchor is a native fragment of the msg body itself
        # (lei-xing = "type", from zig's back-translated "type 'u8' cannot represent 300"),
        # NOT the kind word. Asserting the kind word here would be a false RED (kind never
        # appears in the message field) -- the point is the native msg reached the frame.
        $N_leixing = Native 0x7C7B,0x578B   # lei-xing ("type", back-translated msg body)
        if (-not ($mso[2].Contains($N_leixing) -and $mso[2].Contains('"source":"zzc"') -and $mso[2].Contains('"severity":1') -and $mso[2].Contains('300') -and (-not $mso[2].Contains('"diagnostics":[]')))) { Write-Output "  [FAIL] on-save: didSave did not publish a native semantic diagnostic (check-machine reuse broken)"; $soOk = $false }
    } else {
        Write-Output "  [SKIP] on-save semantic content assert: zig not on PATH (child compile cannot run)"
    }
}
if ($soOk) { Write-Output "  [PASS] on-save guard: didOpen publishes fast-only empty, didSave triggers check-machine compile and publishes native semantic diagnostic (save-gated, not per-keystroke)" }
else { $fail = $fail + 1 }

# --- zzc lsp VS Code CLIENT wiring guard (round 157). extension.js and
# client_frames.js live outside every compiler/test graph -- a broken manifest
# (wrong main/activationEvents/id) or a framing drift is only invisible in the
# editor host unless pinned here. Three faces: (A) manifest cross-contracts,
# (B) node behavior test of the framing layer written to a temp file (never an
# inline -e string: PS 5.1 quote mangling is itself a known false-green trap),
# (C) client<->server shared-truthsource byte asserts (10MB cap spelled alike,
# case-insensitive Content-Length, no completion provider registered -- the
# README claims completions stay declarative). Pure ASCII, forward slashes
# (D52). [SKIP] when node is absent -- skip is loud, silent idle is the real
# enemy (round-103 lesson). Round 158 adds a native-UI contract: the client's
# own user-facing strings (error popup, framing errors, zzc.lspPath settings
# description) must carry CJK and the round-157 English phrasings must be gone
# -- checked with node absent too (pure text contract; CJK probed via a
# \u-escaped regex range so this guard stays ASCII).
Write-Output "== lsp client guard =="
$lcOk = $true
$extDir = Join-Path $root "editors/vscode"
$pkg = Get-Content -Raw (Join-Path $extDir "package.json") -Encoding UTF8 | ConvertFrom-Json
if ($pkg.main -ne "./extension.js") { Write-Output "  [FAIL] client: manifest main is not ./extension.js"; $lcOk = $false }
if (-not (Test-Path (Join-Path $extDir "extension.js"))) { Write-Output "  [FAIL] client: declared main file missing"; $lcOk = $false }
if (-not ($pkg.activationEvents -contains "onLanguage:zig-dialect")) { Write-Output "  [FAIL] client: activation event onLanguage:zig-dialect missing"; $lcOk = $false }
$langId = $pkg.contributes.languages[0].id
if ($langId -ne "zig-dialect") { Write-Output "  [FAIL] client: languages[0].id drifted from zig-dialect"; $lcOk = $false }
if (-not $pkg.contributes.configuration.properties."zzc.lspPath") { Write-Output "  [FAIL] client: zzc.lspPath configuration property missing"; $lcOk = $false }
$extSrc = Get-Content -Raw (Join-Path $extDir "extension.js") -Encoding UTF8
if (-not $extSrc.Contains("const LANGUAGE_ID = 'zig-dialect'")) { Write-Output "  [FAIL] client: LANGUAGE_ID constant no longer matches manifest language id"; $lcOk = $false }
if (-not $extSrc.Contains("'lsp'")) { Write-Output "  [FAIL] client: extension no longer spawns the lsp subcommand"; $lcOk = $false }
if ($extSrc.Contains("registerCompletionItemProvider")) { Write-Output "  [FAIL] client: completion registered via LSP although README keeps it declarative"; $lcOk = $false }
# client didSave wiring (round 160): the client must flip the didSave capability,
# register a save handler, and emit a uri-only textDocument/didSave (server declares
# save{includeText:false}). The raw-JSON-RPC on-save guard (round 159) already proves
# the server side; these pins close the client end-to-end gap in the editor host.
if (-not $extSrc.Contains("didSave: true")) { Write-Output "  [FAIL] client: didSave capability not declared true (server on-save never driven)"; $lcOk = $false }
if (-not $extSrc.Contains("onDidSaveTextDocument")) { Write-Output "  [FAIL] client: onDidSaveTextDocument handler missing (editor save not wired)"; $lcOk = $false }
if (-not $extSrc.Contains("textDocument/didSave")) { Write-Output "  [FAIL] client: didSave notification never sent"; $lcOk = $false }
$saveLine = ($extSrc -split "`n" | Where-Object { $_ -match 'textDocument/didSave' -and $_ -match 'send' }) -join "`n"
if (-not ($saveLine.Length -gt 0) -or ($saveLine -match 'text:')) { Write-Output "  [FAIL] client: didSave must be uri-only (includeText:false contract broken by inline text)"; $lcOk = $false }
# client semanticTokens rendering wiring (round 162): the client must register a
# DocumentSemanticTokensProvider, declare the full semanticTokens capability, request
# textDocument/semanticTokens/full, and hand the server's relative 5-tuples straight to
# vscode.SemanticTokens. The legend is a NEW client<->server shared truth source: its order
# must match the server initialize legend verbatim (each data tuple's type index points into
# it), so it is pinned here -- a reorder silently mis-colors and this assert goes red.
if (-not $extSrc.Contains("registerDocumentSemanticTokensProvider")) { Write-Output "  [FAIL] client: DocumentSemanticTokensProvider not registered (server semantic tokens never painted)"; $lcOk = $false }
if (-not $extSrc.Contains("textDocument/semanticTokens/full")) { Write-Output "  [FAIL] client: textDocument/semanticTokens/full request never sent"; $lcOk = $false }
if (-not $extSrc.Contains("requests: { full: true }")) { Write-Output "  [FAIL] client: full semanticTokens capability not declared"; $lcOk = $false }
if (-not ($extSrc.Contains("new vscode.SemanticTokensLegend(") -and $extSrc.Contains("new vscode.SemanticTokens("))) { Write-Output "  [FAIL] client: SemanticTokens legend/result construction missing (provider cannot build a token set)"; $lcOk = $false }
if (-not $extSrc.Contains("'keyword', 'type', 'function', 'variable', 'string', 'comment', 'number'")) { Write-Output "  [FAIL] client: semantic token legend order drifted from the server legend (data type index would mis-color)"; $lcOk = $false }
$frs = Get-Content -Raw (Join-Path $extDir "client_frames.js") -Encoding UTF8
if (-not $frs.Contains("10 * 1024 * 1024")) { Write-Output "  [FAIL] client: framing cap no longer spelled 10 * 1024 * 1024 (server max_frame_len drift risk)"; $lcOk = $false }
if (-not $frs.Contains("toLowerCase")) { Write-Output "  [FAIL] client: header name match lost case-insensitivity (server parses case-insensitive)"; $lcOk = $false }
# native-UI contract (round 158): the client's own user-facing strings reach a
# pure-native audience -- error popup, framing errors, settings description.
$extHasCjk = ($extSrc -match '[\u4e00-\u9fff]')
if (-not $extHasCjk) { Write-Output "  [FAIL] client: extension.js lost its native (CJK) user-facing text"; $lcOk = $false }
if ($extSrc.Contains("failed to start") -or $extSrc.Contains("Install zzc on PATH")) { Write-Output "  [FAIL] client: English startup error popup leaked to users"; $lcOk = $false }
if ($frs.Contains("invalid frame:") -or $frs.Contains("did not parse back")) { Write-Output "  [FAIL] client: English framing error text leaked"; $lcOk = $false }
$lspDesc = [string]$pkg.contributes.configuration.properties."zzc.lspPath".description
if (-not ($lspDesc -match '[\u4e00-\u9fff]')) { Write-Output "  [FAIL] client: zzc.lspPath settings description not native"; $lcOk = $false }
# client dialect-selection wiring (round 163): the client reads a zzc.lang setting and appends
# `--lang <dialect>` to the `zzc lsp` spawn (the server already honors --lang; rounds 161/162 make
# semantic tokens carry the dialect vocabulary), and restarts the server when zzc.lang (or zzc.lspPath)
# changes so the switch takes effect without a window reload. Pinned as text contracts because the
# vscode-host runtime is not node-behavior testable here.
if (-not $pkg.contributes.configuration.properties."zzc.lang") { Write-Output "  [FAIL] client: zzc.lang configuration property missing"; $lcOk = $false }
$langDesc = [string]$pkg.contributes.configuration.properties."zzc.lang".description
if (-not ($langDesc -match '[\u4e00-\u9fff]')) { Write-Output "  [FAIL] client: zzc.lang settings description not native"; $lcOk = $false }
if (-not ($extSrc.Contains("function lspSpawnArgs") -and $extSrc.Contains("args.push('--lang', l)"))) { Write-Output "  [FAIL] client: zzc.lang not threaded into the lsp spawn as --lang"; $lcOk = $false }
if (-not $extSrc.Contains("cp.spawn(zzcBinary(), lspSpawnArgs()")) { Write-Output "  [FAIL] client: lsp spawn does not use lspSpawnArgs (dialect --lang never reaches the server)"; $lcOk = $false }
if (-not ($extSrc.Contains("onDidChangeConfiguration") -and $extSrc.Contains("affectsConfiguration('zzc.lang')") -and $extSrc.Contains("restartServer"))) { Write-Output "  [FAIL] client: no onDidChangeConfiguration -> restartServer wiring (dialect switch never takes effect)"; $lcOk = $false }
# client overlay-pack wiring (round 267): zzc.langOverlay is threaded into the same
# `zzc lsp` spawn as `--lang-overlay <file>`, so runtime third-party overlay packs
# (contrib/packs/httpz-中文.txt) feed hover/docs in the editor; changing it restarts
# the server. The server-side merge (overlay applied before cmdLsp) is proven
# end-to-end by tools/lsp-live-smoke.sh, which spawns `zzc lsp --lang-overlay <pack>`.
if (-not $pkg.contributes.configuration.properties."zzc.langOverlay") { Write-Output "  [FAIL] client: zzc.langOverlay configuration property missing"; $lcOk = $false }
$ovlDesc = [string]$pkg.contributes.configuration.properties."zzc.langOverlay".description
if (-not ($ovlDesc -match '[\u4e00-\u9fff]')) { Write-Output "  [FAIL] client: zzc.langOverlay settings description not native"; $lcOk = $false }
if (-not ($extSrc.Contains("function zzLangOverlay") -and $extSrc.Contains("args.push('--lang-overlay', o)"))) { Write-Output "  [FAIL] client: zzc.langOverlay not threaded into the lsp spawn as --lang-overlay"; $lcOk = $false }
if (-not $extSrc.Contains("affectsConfiguration('zzc.langOverlay')")) { Write-Output "  [FAIL] client: no restart wiring for zzc.langOverlay (overlay switch never takes effect)"; $lcOk = $false }
# client quick-fix wiring (round 268): registering a CodeActionProvider alone would be a
# dead lightbulb unless the provider actually requests textDocument/codeAction and turns
# the returned literal edit.changes into a vscode.WorkspaceEdit replacement. The server
# side (same danger table as fast diagnostics, ASCII-replacement only) is proven by the
# codeAction unit test and tools/lsp-live-smoke.sh; the extension-host runtime is not
# node-behavior testable here, so the two client seams are pinned as text contracts.
if (-not $extSrc.Contains("registerCodeActionProvider")) { Write-Output "  [FAIL] client: CodeActionProvider not registered (fullwidth quick fixes never surface)"; $lcOk = $false }
if (-not ($extSrc.Contains("textDocument/codeAction") -and $extSrc.Contains("new vscode.WorkspaceEdit()") -and $extSrc.Contains("action.edit.replace("))) { Write-Output "  [FAIL] client: codeAction request or WorkspaceEdit replacement missing (lightbulb would do nothing)"; $lcOk = $false }
# client fix-all wiring (round 269): on save VS Code asks only for source.fixAll, so the
# client must forward context.only (kind -> string array), map the returned kind back to
# vscode.CodeActionKind.SourceFixAll, and advertise both kinds in provider metadata.
# Without the only passthrough the bulk action never fires; without the kind mapping a
# source.fixAll edit would be mislabelled QuickFix and rejected by the save-on-fix filter.
if (-not ($extSrc.Contains("only: codeActionOnly(context.only),") -and $extSrc.Contains("CodeActionKind.SourceFixAll"))) { Write-Output "  [FAIL] client: codeAction context.only passthrough or source.fixAll kind mapping missing (save-time fix-all never fires)"; $lcOk = $false }
if (-not $extSrc.Contains("providedCodeActionKinds")) { Write-Output "  [FAIL] client: providedCodeActionKinds metadata missing (VS Code cannot route source.fixAll to this provider)"; $lcOk = $false }
# client folding wiring (round 270/271): registering a FoldingRangeProvider is only
# useful if it actually requests textDocument/foldingRange and maps the returned
# startLine/endLine into vscode.FoldingRange. The server's brace pairing (lexer
# tokens keep strings/comments out) and consecutive comment blocks are proven by
# the unit test and the FIFO smoke; the extension-host provider seam is pinned as
# a text contract here.
if (-not $extSrc.Contains("registerFoldingRangeProvider")) { Write-Output "  [FAIL] client: FoldingRangeProvider not registered (editor folding never reflects brace blocks)"; $lcOk = $false }
if (-not ($extSrc.Contains("textDocument/foldingRange") -and $extSrc.Contains("new vscode.FoldingRange(") -and $extSrc.Contains("vscode.FoldingRangeKind.Comment"))) { Write-Output "  [FAIL] client: foldingRange request, FoldingRange mapping, or comment kind mapping missing (provider would return nothing or lose the comment colour)"; $lcOk = $false }
# client rename wiring (round 272): the provider is only useful if it requests
# textDocument/rename with the new name and rebuilds WorkspaceEdit from res.changes.
if (-not $extSrc.Contains("registerRenameProvider")) { Write-Output "  [FAIL] client: RenameProvider not registered (F2 rename never reaches the server)"; $lcOk = $false }
if (-not ($extSrc.Contains("textDocument/rename") -and $extSrc.Contains("newName,") -and $extSrc.Contains("Object.entries(res.changes)"))) { Write-Output "  [FAIL] client: rename request/newName passthrough or changes-map rebuild missing (edits would apply nowhere)"; $lcOk = $false }
# client prepare-rename wiring (round 274): F2 must pre-check the cursor through
# textDocument/prepareRename and feed the returned range/placeholder back to VS Code;
# otherwise non-declaration words still open a dead rename box (rename then returns null).
if (-not ($extSrc.Contains("prepareRename: async") -and $extSrc.Contains("textDocument/prepareRename") -and $extSrc.Contains("placeholder: res.placeholder"))) { Write-Output "  [FAIL] client: prepareRename request/range/placeholder passthrough missing (F2 opens a dead rename box on non-declaration words)"; $lcOk = $false }
# client document-highlight wiring (round 273): registering a DocumentHighlightProvider is
# only useful if it requests textDocument/documentHighlight and maps the returned range and
# kind into vscode.DocumentHighlight (Write for the declaration, Read for references).
if (-not $extSrc.Contains("registerDocumentHighlightProvider")) { Write-Output "  [FAIL] client: DocumentHighlightProvider not registered (same-symbol occurrences never highlight)"; $lcOk = $false }
if (-not ($extSrc.Contains("textDocument/documentHighlight") -and $extSrc.Contains("new vscode.DocumentHighlight(") -and $extSrc.Contains("vscode.DocumentHighlightKind.Write"))) { Write-Output "  [FAIL] client: documentHighlight request, range mapping, or Write/Read kind mapping missing (provider would return nothing or lose the declaration/read distinction)"; $lcOk = $false }
# client workspace-symbol wiring (round 275): the provider is only useful if it
# requests workspace/symbol with the query and rebuilds a vscode.SymbolInformation
# (location.uri + location.range) from each returned item; otherwise "Go to Symbol
# in Workspace" never reaches the open-document table.
if (-not ($extSrc.Contains("registerWorkspaceSymbolProvider") -and $extSrc.Contains("workspace/symbol") -and $extSrc.Contains("new vscode.SymbolInformation(") -and $extSrc.Contains("s.location.uri"))) { Write-Output "  [FAIL] client: workspace/symbol request or SymbolInformation location mapping missing (Go to Symbol in Workspace never returns open-document symbols)"; $lcOk = $false }
# client signature-help wiring (round 276): typing inside a call paren must trigger
# textDocument/signatureHelp and rebuild vscode.SignatureHelp (signatures, parameter
# labels, activeParameter); otherwise the popup never opens or loses the parameter list.
if (-not ($extSrc.Contains("registerSignatureHelpProvider") -and $extSrc.Contains("textDocument/signatureHelp") -and $extSrc.Contains("new vscode.SignatureInformation(") -and $extSrc.Contains("new vscode.ParameterInformation(") -and $extSrc.Contains("activeParameter: res.activeParameter"))) { Write-Output "  [FAIL] client: signatureHelp request or SignatureInformation/ParameterInformation mapping missing (call-paren popup never shows the declaration parameter list or active parameter)"; $lcOk = $false }
# client selection-range wiring (round 277): Expand Selection must request
# textDocument/selectionRange with every cursor position and rebuild the returned
# range/parent chain as vscode.SelectionRange; otherwise it stops at the word/line.
if (-not ($extSrc.Contains("registerSelectionRangeProvider") -and $extSrc.Contains("textDocument/selectionRange") -and $extSrc.Contains("new vscode.SelectionRange(") -and $extSrc.Contains("toSelectionRange(r.parent)"))) { Write-Output "  [FAIL] client: selectionRange request or SelectionRange parent-chain mapping missing (Expand Selection never reaches the enclosing block or whole document)"; $lcOk = $false }
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Output "  [SKIP] client behavior test: node not on PATH"
} else {
    $cprobe = Join-Path $root ".zig-cache/lsp_client_probe.js"
    $cline = @()
    $cline += 'const { encodeFrame, FrameDecoder, roundTrip, MAX_FRAME_BYTES } = require(process.argv[2]);'
    $cline += 'let fail = 0; let ran = 0;'
    $cline += 'function ok(n, c) { ran++; if (!c) { console.log("FAIL " + n); fail++; } }'
    $cline += 'ok("method-echo", roundTrip("{\"jsonrpc\":\"2.0\",\"id\":1}").json.id === 1);'
    $cline += 'const cjk = Buffer.from("{\"t\":\"\u4e2d\u6587\u65b9\u8a00\"}");'
    $cline += 'const f = encodeFrame(cjk.toString("utf8"));'
    $cline += 'const m = /Content-Length: (\d+)/.exec(f.subarray(0, 40).toString("latin1"));'
    $cline += 'ok("cjk-byte-len", Number(m[1]) === cjk.length);'
    $cline += 'ok("cjk-roundtrip", roundTrip(cjk.toString("utf8")).json.t.length === 4);'
    $cline += 'const d = new FrameDecoder();'
    $cline += 'd.append(Buffer.concat([encodeFrame("{\"a\":1}"), encodeFrame("{\"b\":2}")]));'
    $cline += 'let n = 0; for (;;) { if (!d.take()) break; n++; }'
    $cline += 'ok("glued-two", n === 2);'
    # CRLF is built with fromCharCode because a literal \r\n inside these
    # single-quoted PS strings does not survive every console/transcode path.
    $cline += 'const CRLF = String.fromCharCode(13, 10) + String.fromCharCode(13, 10);'
    $cline += 'const p = new FrameDecoder(); p.append(Buffer.from("Content-Length: 7" + CRLF + "12345"));'
    $cline += 'ok("partial-null", p.take() === null);'
    $cline += 'p.append(Buffer.from("67"));'
    $cline += 'ok("partial-completes", (p.take() || { json: 0 }).json === 1234567);'
    $cline += 'const bad = new FrameDecoder(); bad.append(Buffer.from("Nope: 1" + CRLF + "{}"));'
    $cline += 'let t1 = 0; try { bad.take(); } catch (e) { t1 = 1; }'
    $cline += 'ok("no-cl-throws", t1 === 1);'
    $cline += 'const big = new FrameDecoder(); big.append(Buffer.from("Content-Length: " + (MAX_FRAME_BYTES + 1) + CRLF));'
    $cline += 'let t2 = 0; try { big.take(); } catch (e) { t2 = 1; }'
    $cline += 'ok("oversize-throws", t2 === 1);'
    $cline += 'const ci = new FrameDecoder(); ci.append(Buffer.from("content-length: 2" + CRLF + "{}"));'
    $cline += 'ok("cl-case-insensitive", (ci.take() || { body: "" }).body === "{}");'
    $cline += 'console.log("asserts=" + ran);'
    $cline += 'process.exit(fail === 0 ? 0 : 1);'
    Set-Content -Path $cprobe -Value ($cline -join "`n") -Encoding ASCII
    $cnodeOut = ((& node $cprobe (Join-Path $extDir "client_frames.js") 2>&1) | Out-String)
    $cnodeExit = $LASTEXITCODE
    foreach ($cl in ($cnodeOut -split '[\r\n]+')) {
        if ($cl.Trim().Length -gt 0) { Write-Output ("  node: " + $cl.Trim()) }
    }
    if ($cnodeExit -ne 0) { Write-Output "  [FAIL] client: framing behavior test exited $cnodeExit"; $lcOk = $false }
    # anti-silent-idle (round-103 lesson): the probe must report every assert it
    # actually ran, otherwise a probe that never starts would still look green.
    if (-not $cnodeOut.Contains("asserts=9")) { Write-Output "  [FAIL] client: framing probe did not report its 9 asserts (silent idle?)"; $lcOk = $false }
    Remove-Item -Force $cprobe -ErrorAction SilentlyContinue
    & node --check (Join-Path $extDir "extension.js") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Output "  [FAIL] client: extension.js does not parse under node --check"; $lcOk = $false }
}
if ($lcOk) { Write-Output "  [PASS] client guard: manifest main/activation/id/config contracts, framing behavior (byte-counted CJK, glued/partial/malformed/oversize/case-insensitive), shared 10MB cap, declarative-completions invariant, native-UI contract (CJK popup/framing/settings, round-157 English gone), client didSave wiring (capability flipped, save handler, uri-only didSave emit), client semanticTokens rendering (provider registered, full capability, /full request, legend order pinned to server), client dialect selection (zzc.lang property + native description, --lang threaded into lspSpawnArgs spawn, onDidChangeConfiguration -> restartServer)" }
else { $fail = $fail + 1 }

if ($fail -gt 0) { throw ("$fail demo(s)/guard(s) failed the baseline check") }
Write-Output "all demos: dialect and graduated Zig behave identically"
