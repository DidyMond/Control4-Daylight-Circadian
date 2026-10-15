#Requires -Version 5.1
<#
  .SYNOPSIS
    Esegue i test offline di libs/ con LuaJIT (stessa semantica Lua 5.1 di
    DriverWorks) e fa il lint di libs/.

  .DESCRIPTION
    1. Lint statico di libs/*.lua: solo Lua 5.1 puro e nessun riferimento a
       C4 (niente goto, //, operatori bit a bit, API post-5.1).
    2. Ogni tests/test_*.lua viene eseguito in un processo separato, con la
       radice del repo come cartella di lavoro (quindi `require "libs.xxx"` e
       `require "tests.support.harness"` funzionano). Le righe PASS/FAIL dei
       singoli test sono stampate cosi' come arrivano.
    Al primo fallimento (lint o test) lo script si ferma con exit code 1.
    Exit code 0 solo se tutto e' verde.

    Interprete: luajit nel PATH; in alternativa il percorso di default di
    winget (DEVCOM.LuaJIT) o un lua 5.1 nel PATH.

  .EXAMPLE
    ./tools/run_tests.ps1
    ./tools/run_tests.ps1 -Filter debug      # solo tests/test_*debug*.lua
#>
param(
    [string]$Filter = "",
    [switch]$Quiet     # solo riepilogo per file e righe non-PASS (output corto)
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Find-Lua {
    foreach ($name in @("luajit", "lua5.1", "lua51")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $wingetDefault = Join-Path $env:LOCALAPPDATA "Programs\LuaJIT\bin\luajit.exe"
    if (Test-Path $wingetDefault) { return $wingetDefault }
    return $null
}

$lua = Find-Lua
if (-not $lua) {
    Write-Host "Interprete Lua non trovato. Installa LuaJIT: winget install --id DEVCOM.LuaJIT -e" -ForegroundColor Red
    exit 1
}
Write-Host "==> Interprete: $lua" -ForegroundColor Cyan

# ------------------------------------------------------------
# 1. Lint di libs/ (Lua 5.1 puro, nessun C4)
# ------------------------------------------------------------
Write-Host "==> Lint libs/" -ForegroundColor Cyan
$rules = @(
    @{ Pattern = '\bC4\b';                       Why = "riferimento a C4 (le libs devono essere pure)" },
    @{ Pattern = '\bgoto\b|::\w+::';             Why = "goto/label (Lua 5.2+)" },
    @{ Pattern = '//';                           Why = "divisione intera // (Lua 5.3+)" },
    @{ Pattern = '<<|>>|[^~=<>]~[^=]|&|\|';      Why = "operatori bit a bit (Lua 5.3+)" },
    @{ Pattern = '\bbit32\b|\butf8\b';           Why = "libreria post-5.1" },
    @{ Pattern = 'table\.(pack|unpack|move)\b';  Why = "table.pack/unpack/move (5.2+; in 5.1 usa il globale unpack)" },
    @{ Pattern = 'string\.(pack|unpack|packsize)\b'; Why = "string.pack/unpack (5.3+)" },
    @{ Pattern = 'math\.(tointeger|ult|type)\b'; Why = "API math 5.3+" },
    @{ Pattern = '\b_ENV\b';                     Why = "_ENV (Lua 5.2+)" }
)
$lintFailed = $false
foreach ($file in (Get-ChildItem (Join-Path $repoRoot "libs") -Recurse -Filter *.lua)) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    # commenti a blocco, poi commenti di riga, poi contenuto delle stringhe
    $text = [regex]::Replace($text, '(?s)--\[(=*)\[.*?\]\1\]', '')
    $lineNo = 0
    foreach ($line in ($text -split "`n")) {
        $lineNo++
        $code = [regex]::Replace($line, '--.*$', '')
        $code = [regex]::Replace($code, '"([^"\\]|\\.)*"', '""')
        $code = [regex]::Replace($code, "'([^'\\]|\\.)*'", "''")
        foreach ($rule in $rules) {
            if ($code -match $rule.Pattern) {
                Write-Host ("  FAIL {0}:{1} {2}" -f $file.Name, $lineNo, $rule.Why) -ForegroundColor Red
                $lintFailed = $true
            }
        }
    }
    # sintassi (compilazione senza esecuzione)
    & $lua -e "local f, e = loadfile([[$($file.FullName)]]); if not f then io.stderr:write(e, '\n'); os.exit(1) end"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL $($file.Name): errore di sintassi" -ForegroundColor Red
        $lintFailed = $true
    }
    if ((-not $lintFailed) -and (-not $Quiet)) { Write-Host "  PASS $($file.Name)" -ForegroundColor Green }
}
if ($lintFailed) { exit 1 }

# ------------------------------------------------------------
# 2. Test
# ------------------------------------------------------------
$tests = Get-ChildItem (Join-Path $repoRoot "tests") -Filter "test_*.lua" | Sort-Object Name
if ($Filter) { $tests = $tests | Where-Object { $_.Name -like "*$Filter*" } }
if (-not $tests) {
    Write-Host "Nessun test trovato." -ForegroundColor Yellow
    exit 1
}

Push-Location $repoRoot
try {
    foreach ($test in $tests) {
        Write-Host "==> $($test.Name)" -ForegroundColor Cyan
        $output = & $lua $test.FullName 2>&1
        $exitCode = $LASTEXITCODE
        if ($Quiet) {
            $output | Where-Object { $_ -notmatch '^\s+PASS ' } | ForEach-Object { Write-Host $_ }
        } else {
            $output | ForEach-Object { Write-Host $_ }
        }
        if ($exitCode -ne 0) {
            Write-Host "==> FAIL: $($test.Name) (exit $exitCode). Interrotto." -ForegroundColor Red
            exit 1
        }
        # Ogni file deve chiudere con t.finish(): senza, un test fallito non
        # darebbe exit code != 0. Il riepilogo "-- N PASS, M FAIL" ne e' la prova.
        if (-not ($output | Where-Object { $_ -match '^\s+-- \d+ PASS, \d+ FAIL' })) {
            Write-Host "==> FAIL: $($test.Name) non ha stampato il riepilogo (manca t.finish()?). Interrotto." -ForegroundColor Red
            exit 1
        }
    }
} finally {
    Pop-Location
}

# ------------------------------------------------------------
# 3. Test JS della webview (solo se c'e' node: sono solo sviluppo, il runtime non ne ha bisogno)
# ------------------------------------------------------------
$jsCount = 0
$node = Get-Command node -ErrorAction SilentlyContinue
$jsTests = Get-ChildItem (Join-Path $repoRoot "tests/js") -Filter "test_*.js" -ErrorAction SilentlyContinue | Sort-Object Name
if ($Filter) { $jsTests = $jsTests | Where-Object { $_.Name -like "*$Filter*" } }
if ($jsTests -and -not $node) {
    Write-Host "==> node non trovato: salto i test JS (tests/js)" -ForegroundColor Yellow
} elseif ($jsTests) {
    Push-Location $repoRoot
    try {
        foreach ($test in $jsTests) {
            Write-Host "==> $($test.Name)" -ForegroundColor Cyan
            $output = & node $test.FullName 2>&1
            $exitCode = $LASTEXITCODE
            if ($Quiet) {
                $output | Where-Object { $_ -notmatch '^\s+PASS ' } | ForEach-Object { Write-Host $_ }
            } else {
                $output | ForEach-Object { Write-Host $_ }
            }
            if ($exitCode -ne 0) {
                Write-Host "==> FAIL: $($test.Name) (exit $exitCode). Interrotto." -ForegroundColor Red
                exit 1
            }
            if (-not ($output | Where-Object { $_ -match '^\s+-- \d+ PASS, \d+ FAIL' })) {
                Write-Host "==> FAIL: $($test.Name) non ha stampato il riepilogo. Interrotto." -ForegroundColor Red
                exit 1
            }
            $jsCount++
        }
    } finally {
        Pop-Location
    }
}

$total = @($tests).Count + $jsCount
Write-Host "==> TUTTI I TEST PASS ($total file)" -ForegroundColor Green
exit 0
