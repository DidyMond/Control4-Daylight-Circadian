#Requires -Version 5.1
<#
  .SYNOPSIS
    Pacchettizza un driver della suite (controller o webview) in un .c4z
    pronto per Composer Pro.

  .DESCRIPTION
    Un .c4z e' uno zip con driver.xml, driver.lua, libs/ e www/ alla RADICE
    dell'archivio (non annidati dentro "drivers/<nome>"). Questo script:
      1. Incrementa <version> in driver.xml (formato YYMMDDNNN). Composer
         Pro non ricarica un driver gia' installato se <version> non
         aumenta (saltabile con -NoBump).
      2. Crea releases/<driver_name>.c4z con driver.xml, driver.lua e www/
         del driver, piu' la cartella libs/ condivisa della radice del repo
         (copiata come libs/ nella radice del .c4z, cosi' funziona
         `require "libs.debug"`).

    Pattern verificato su hardware con Composer Pro: System.IO.Compression, SOLO file (nessuna voce di directory),
    separatore "/" nei nomi delle voci (Compress-Archive scrive "\" e puo'
    far fallire la lettura in Composer).

    Il nome del .c4z DEVE coincidere con <driver_name> in driver.xml
    (controller://driver/<driver_name>/... dipende da questo).

  .EXAMPLE
    ./tools/build.ps1
    ./tools/build.ps1 -Driver webview
    ./tools/build.ps1 -NoBump
#>
param(
    [ValidateSet("controller", "webview")]
    [string]$Driver = "controller",
    [switch]$NoBump
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$libsDir = Join-Path $repoRoot "libs"
$buildDir = Join-Path $repoRoot "releases"

# cartella sorgente -> nome driver / se include libs/
$drivers = @{
    # Libs = $null: tutte; altrimenti solo i file indicati (il webview non ha bisogno del motore)
    controller = @{ Name = "daylight_circadian_controller"; IncludeLibs = $true; Libs = $null }
    webview    = @{ Name = "daylight_circadian_webview";    IncludeLibs = $true
                    Libs = @("debug.lua", "json.lua", "protocol.lua", "schedule.lua", "curve.lua", "hub.lua") }
}
$driverName = $drivers[$Driver].Name
$includeLibs = $drivers[$Driver].IncludeLibs
$libsFilter = $drivers[$Driver].Libs
$srcDir = Join-Path $repoRoot "drivers\$Driver"
$driverXmlPath = Join-Path $srcDir "driver.xml"
$c4zPath = Join-Path $buildDir "$driverName.c4z"

if (-not (Test-Path $driverXmlPath)) {
    throw "driver.xml non trovato in $driverXmlPath (driver '$Driver' non ancora implementato?)"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$driverXmlContent = [System.IO.File]::ReadAllText($driverXmlPath, $utf8NoBom)

# Il nome del file deve combaciare con <driver_name>.
$nameMatch = [regex]::Match($driverXmlContent, '<driver_name>([^<]+)</driver_name>')
if (-not $nameMatch.Success -or $nameMatch.Groups[1].Value -ne $driverName) {
    throw "<driver_name> in driver.xml deve essere '$driverName'"
}

# ------------------------------------------------------------
# 1. Bump di <version> (YYMMDDNNN)
# ------------------------------------------------------------
if (-not $NoBump) {
    Write-Host "==> Aggiorno <version> in driver.xml..." -ForegroundColor Cyan
    $versionMatch = [regex]::Match($driverXmlContent, '<version>(\d{6})(\d{3})</version>')
    if (-not $versionMatch.Success) {
        throw "Tag <version>YYMMDDNNN</version> non trovato in $driverXmlPath"
    }
    $oldDatePart = $versionMatch.Groups[1].Value
    $oldSeq = [int]$versionMatch.Groups[2].Value
    $oldVersion = $oldDatePart + $versionMatch.Groups[2].Value

    $today = Get-Date -Format "yyMMdd"
    if ($oldDatePart -eq $today) {
        $newSeq = $oldSeq + 1
    } else {
        $newSeq = 1
    }
    $newVersion = $today + ("{0:D3}" -f $newSeq)
    if ([long]$newVersion -le [long]$oldVersion) {
        # orologio indietro rispetto alla versione corrente: mai diminuire
        $newVersion = [string]([long]$oldVersion + 1)
    }

    $driverXmlContent = $driverXmlContent.Substring(0, $versionMatch.Index) `
        + "<version>$newVersion</version>" `
        + $driverXmlContent.Substring($versionMatch.Index + $versionMatch.Length)
    # Anche il default della proprieta' read-only "Driver Version"
    $driverXmlContent = [regex]::Replace($driverXmlContent,
        '(<name>Driver Version</name>\s*<type>STRING</type>\s*<default>)\d+(</default>)',
        ('${1}' + $newVersion + '${2}'))
    [System.IO.File]::WriteAllText($driverXmlPath, $driverXmlContent, $utf8NoBom)
    Write-Host "    $oldVersion -> $newVersion"
}

# ------------------------------------------------------------
# 2. Pacchettizzazione
# ------------------------------------------------------------
Write-Host "==> Creo $driverName.c4z..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
if (Test-Path $c4zPath) { Remove-Item -Force -Confirm:$false $c4zPath }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tempZipPath = Join-Path $buildDir "$driverName.zip"
if (Test-Path $tempZipPath) { Remove-Item -Force -Confirm:$false $tempZipPath }

# Versione corrente (dopo l'eventuale bump): finisce negli URL di CSS/JS della webview, cosi' un
# aggiornamento del driver non puo' lasciare in cache sul pannello file di una versione vecchia.
$stampMatch = [regex]::Match($driverXmlContent, '<version>(\d+)</version>')
$buildStamp = if ($stampMatch.Success) { $stampMatch.Groups[1].Value } else { "0" }

# Solo questi file/cartelle entrano nel pacchetto (niente README, test, ecc.)
function Add-FilesToZip($zipArchive, $baseDir, $prefix, $includeTopFiles, $onlyNames) {
    Push-Location $baseDir
    try {
        foreach ($file in (Get-ChildItem -Recurse -File)) {
            $rel = (Resolve-Path -LiteralPath $file.FullName -Relative)
            if ($rel.StartsWith(".\") -or $rel.StartsWith("./")) { $rel = $rel.Substring(2) }
            $rel = $rel.Replace([char]92, [char]47)
            if ($rel.EndsWith(".md")) { continue }
            if ($null -ne $onlyNames -and ($onlyNames -notcontains $file.Name)) { continue }
            if ($null -ne $includeTopFiles) {
                $top = $rel.Split("/")[0]
                if ($includeTopFiles -notcontains $top) { continue }
            }
            $entryName = $prefix + $rel
            if ($rel -eq "www/dist/index.html") {
                # sostituisce __BUILD__ con la versione del driver (in sviluppo resta il segnaposto)
                $html = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom).Replace("__BUILD__", $buildStamp)
                $entry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $stream = $entry.Open()
                try {
                    $bytes = $utf8NoBom.GetBytes($html)
                    $stream.Write($bytes, 0, $bytes.Length)
                } finally {
                    $stream.Dispose()
                }
            } else {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zipArchive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
            Write-Host "    + $entryName"
        }
    } finally {
        Pop-Location
    }
}

$zip = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Add-FilesToZip $zip $srcDir "" @("driver.xml", "driver.lua", "www") $null
    if ($includeLibs) {
        if (-not (Test-Path $libsDir)) { throw "Cartella libs/ non trovata: $libsDir" }
        Add-FilesToZip $zip $libsDir "libs/" $null $libsFilter
    }
} finally {
    $zip.Dispose()
}

Rename-Item -Path $tempZipPath -NewName "$driverName.c4z"
Write-Host "==> Fatto: $c4zPath" -ForegroundColor Green
