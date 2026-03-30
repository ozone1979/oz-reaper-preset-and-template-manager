# Release Checklist

Use this for each new ReaPack version.

## 1) Pre-flight

- Be on `main`.
- Ensure working tree is clean:
  - `git status --short`
- Ensure GitHub auth is active:
  - `gh auth status`

## 2) Publish a version

Replace `X.Y.Z` with the next version (for example `0.1.1`):

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\publish-reapack-release.ps1 -Version "X.Y.Z" -GithubOwner "YOUR_USERNAME" -RepoName "oz-reaper-preset-and-template-manager" -Author "YOUR_NAME"
```

This command automatically:

1. Regenerates `index.xml` pinned to `vX.Y.Z`.
2. Commits updated `index.xml`.
3. Creates annotated tag `vX.Y.Z`.
4. Pushes `main` and the tag.
5. Creates a GitHub release.

## 3) Verify the release

- Release exists:
  - `gh release view vX.Y.Z --repo YOUR_USERNAME/oz-reaper-preset-and-template-manager`
- Feed has the new version and only tag-pinned URLs:

```powershell
$u='https://raw.githubusercontent.com/YOUR_USERNAME/oz-reaper-preset-and-template-manager/main/index.xml'
$c=(Invoke-WebRequest -UseBasicParsing -Uri $u).Content
$versionOk=($c -match '<version name="X.Y.Z"')
$sources=[regex]::Matches($c,'<source[^>]*>(.*?)</source>',[System.Text.RegularExpressions.RegexOptions]::Singleline) | ForEach-Object { $_.Groups[1].Value.Trim() }
$bad=$sources | Where-Object { $_ -notmatch '/vX\.Y\.Z/' }
"version_ok=$versionOk"
"source_count=$($sources.Count)"
"bad_source_count=$($bad.Count)"
```

Expected:

- `version_ok=True`
- `bad_source_count=0`
