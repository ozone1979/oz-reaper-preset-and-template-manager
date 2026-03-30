param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$GithubOwner = "ozone1979",
    [string]$RepoName = "oz-reaper-preset-and-template-manager",
    [string]$Author,
    [string]$Remote = "origin",
    [switch]$SkipGitHubRelease
)

$ErrorActionPreference = "Stop"

if (-not $Author) {
    $Author = $GithubOwner
}

if ($Version.StartsWith("v")) {
    $Version = $Version.Substring(1)
}

if (-not ($Version -match "^\d+\.\d+\.\d+(?:[-+].+)?$")) {
    throw "Version must look like 0.1.0 or 0.1.0-beta"
}

$tag = "v$Version"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$dirty = git status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw "git status failed"
}
if ($dirty) {
    throw "Working tree is not clean. Commit or stash changes before publishing."
}

$existingLocalTag = git tag --list $tag
if ($existingLocalTag) {
    throw "Tag already exists locally: $tag"
}

$existingRemoteTag = git ls-remote --tags $Remote $tag
if ($existingRemoteTag) {
    throw "Tag already exists on remote '$Remote': $tag"
}

$generator = Join-Path $PSScriptRoot "generate-reapack-index.ps1"
if (-not (Test-Path $generator)) {
    throw "Missing generator script: $generator"
}

& $generator -GithubOwner $GithubOwner -RepoName $RepoName -Branch $tag -Version $Version -Author $Author

$readmePath = Join-Path $repoRoot "README.md"
if (Test-Path $readmePath) {
    $readme = Get-Content -Path $readmePath -Raw -Encoding UTF8
    $releaseUrl = "https://github.com/$GithubOwner/$RepoName/releases/tag/$tag"
    $latestReleaseLine = '- `{0}` — `{1}`' -f $tag, $releaseUrl

    $updatedReadme = [regex]::Replace(
        $readme,
        '(?m)^- `v[^`]+` — `https://github\.com/[^`]+/releases/tag/v[^`]+`$'
        ,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            $latestReleaseLine
        },
        1
    )

    if ($updatedReadme -eq $readme) {
        $eol = if ($readme -match "`r`n") { "`r`n" } else { "`n" }
        $updatedReadme = [regex]::Replace(
            $readme,
            '(?m)^Latest release:\s*$'
            ,
            "Latest release:$eol$eol$latestReleaseLine",
            1
        )
    }

    if ($updatedReadme -ne $readme) {
        Set-Content -Path $readmePath -Value $updatedReadme -Encoding UTF8
    }
}

$indexDiff = git diff --name-only -- index.xml
if (-not $indexDiff) {
    throw "index.xml was not changed by generator. Aborting to avoid an empty release commit."
}

if (Test-Path $readmePath) {
    git add index.xml README.md
} else {
    git add index.xml
}
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stage release files"
}

git commit -m "Prepare ReaPack release $tag"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create release prep commit"
}

git tag -a $tag -m "Release $tag"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create tag $tag"
}

git push $Remote main
if ($LASTEXITCODE -ne 0) {
    throw "Failed to push main"
}

git push $Remote $tag
if ($LASTEXITCODE -ne 0) {
    throw "Failed to push tag $tag"
}

if (-not $SkipGitHubRelease) {
    $repoFull = "$GithubOwner/$RepoName"
    $gh = "gh"
    $ghPath = "C:\Program Files\GitHub CLI\gh.exe"
    if (Test-Path $ghPath) {
        $gh = $ghPath
    }

    & $gh release create $tag --repo $repoFull --title $tag --generate-notes
    if ($LASTEXITCODE -ne 0) {
        throw "Tag pushed but failed to create GitHub release."
    }
}

Write-Output "Published $tag"
Write-Output "Repo: https://github.com/$GithubOwner/$RepoName"
Write-Output "Feed: https://raw.githubusercontent.com/$GithubOwner/$RepoName/main/index.xml"
