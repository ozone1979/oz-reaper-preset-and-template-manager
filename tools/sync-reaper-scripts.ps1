param(
    [string]$DestinationRoot = (Join-Path $env:APPDATA "REAPER\Scripts\Oz Reaper Preset and Template Manager\Scripts"),
    [string]$SourceRoot,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"

if (-not $SourceRoot) {
    $SourceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
}

$SourceRoot = (Resolve-Path $SourceRoot).Path
$DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)

$sourceCore = Join-Path $SourceRoot "Oz PTM Core.lua"
$sourceActions = Join-Path $SourceRoot "actions"
$sourceLibs = Join-Path $SourceRoot "libs"

if (-not (Test-Path -LiteralPath $sourceCore)) {
    throw "Missing source core file: $sourceCore"
}

if (-not (Test-Path -LiteralPath $sourceActions)) {
    throw "Missing source actions folder: $sourceActions"
}

if (-not (Test-Path -LiteralPath $sourceLibs)) {
    throw "Missing source libs folder: $sourceLibs"
}

if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    New-Item -ItemType Directory -Path $DestinationRoot | Out-Null
}

$destinationActions = Join-Path $DestinationRoot "actions"
$destinationLibs = Join-Path $DestinationRoot "libs"

if (-not (Test-Path -LiteralPath $destinationActions)) {
    New-Item -ItemType Directory -Path $destinationActions | Out-Null
}

if (-not (Test-Path -LiteralPath $destinationLibs)) {
    New-Item -ItemType Directory -Path $destinationLibs | Out-Null
}

Copy-Item -LiteralPath $sourceCore -Destination (Join-Path $DestinationRoot "Oz PTM Core.lua") -Force
Copy-Item -Path (Join-Path $sourceActions "*") -Destination $destinationActions -Recurse -Force
Copy-Item -Path (Join-Path $sourceLibs "*") -Destination $destinationLibs -Recurse -Force

$actionFiles = @(Get-ChildItem -Path $sourceActions -File -Recurse)
$libFiles = @(Get-ChildItem -Path $sourceLibs -File -Recurse)

if ($Verify) {
    $mismatches = @()
    $filesToVerify = @(
    "Oz PTM Core.lua"
    ) +
    ($actionFiles | ForEach-Object { "actions/" + $_.FullName.Substring($sourceActions.Length + 1).Replace("\", "/") }) +
    ($libFiles | ForEach-Object { "libs/" + $_.FullName.Substring($sourceLibs.Length + 1).Replace("\", "/") })

    foreach ($relativePath in $filesToVerify) {
        $src = Join-Path $SourceRoot ($relativePath -replace "/", "\\")
        $dst = Join-Path $DestinationRoot ($relativePath -replace "/", "\\")

        if (-not (Test-Path -LiteralPath $dst)) {
            $mismatches += "$relativePath :: missing in destination"
            continue
        }

        $srcHash = (Get-FileHash -LiteralPath $src).Hash
        $dstHash = (Get-FileHash -LiteralPath $dst).Hash

        if ($srcHash -ne $dstHash) {
            $mismatches += "$relativePath :: content mismatch"
        }
    }

    if ($mismatches.Count -gt 0) {
        throw "Verification failed:`n - $($mismatches -join "`n - ")"
    }
}

Write-Output "Sync complete."
Write-Output "Source: $SourceRoot"
Write-Output "Destination: $DestinationRoot"
Write-Output "Copied core: 1 file"
Write-Output "Copied actions: $($actionFiles.Count) files"
Write-Output "Copied libs: $($libFiles.Count) files"

if ($Verify) {
    Write-Output "Verification: passed"
}
