param(
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$chineseRoot = Join-Path $rootPath 'zh-CN'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$imageExtensions = @('.gif', '.jpeg', '.jpg', '.png', '.svg', '.webp')
$textExtensions = @('.css', '.html', '.js', '.svg')

if (-not (Test-Path -LiteralPath $chineseRoot -PathType Container)) {
    Write-Host 'Translated asset deduplication complete. No zh-CN directory found.'
    exit 0
}

function Get-RelativeWebPath {
    param(
        [string]$FromDirectory,
        [string]$ToFile
    )

    $fromPath = [System.IO.Path]::GetFullPath($FromDirectory).TrimEnd('\') + '\'
    $toPath = [System.IO.Path]::GetFullPath($ToFile)
    $fromUri = New-Object System.Uri($fromPath)
    $toUri = New-Object System.Uri($toPath)
    return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString())
}

function Replace-StandaloneReference {
    param(
        [string]$Content,
        [string]$OldReference,
        [string]$NewReference
    )

    $pattern = '(?<![A-Za-z0-9_.%/\-])' + [regex]::Escape($OldReference)
    return [regex]::Replace(
        $Content,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $NewReference
        }
    )
}

function Test-StandaloneReference {
    param(
        [string]$Content,
        [string]$Reference
    )

    $pattern = '(?<![A-Za-z0-9_.%/\-])' + [regex]::Escape($Reference)
    return [regex]::IsMatch($Content, $pattern)
}

$candidates = foreach ($chineseFile in (
    Get-ChildItem -Path $chineseRoot -Recurse -File |
        Where-Object {
            $imageExtensions -contains $_.Extension.ToLowerInvariant() -and
            $_.FullName -match '\\assets\\'
        }
)) {
    $relativePath = $chineseFile.FullName.Substring($chineseRoot.Length).TrimStart('\')
    $englishPath = Join-Path $rootPath $relativePath

    if (-not (Test-Path -LiteralPath $englishPath -PathType Leaf)) {
        continue
    }

    if ($chineseFile.Length -ne (Get-Item -LiteralPath $englishPath).Length) {
        continue
    }

    $chineseHash = (Get-FileHash -LiteralPath $chineseFile.FullName -Algorithm SHA256).Hash
    $englishHash = (Get-FileHash -LiteralPath $englishPath -Algorithm SHA256).Hash
    if ($chineseHash -ne $englishHash) {
        continue
    }

    [PSCustomObject]@{
        Chinese = $chineseFile.FullName
        English = $englishPath
        Bytes = $chineseFile.Length
    }
}

if (-not $candidates) {
    Write-Host 'Translated asset deduplication complete. No exact English/Chinese image copies found.'
    exit 0
}

$candidateKeys = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($candidate in $candidates) {
    $null = $candidateKeys.Add([System.IO.Path]::GetFullPath($candidate.Chinese))
}

$textFiles = Get-ChildItem -Path $chineseRoot -Recurse -File |
    Where-Object {
        $textExtensions -contains $_.Extension.ToLowerInvariant() -and
        -not $candidateKeys.Contains([System.IO.Path]::GetFullPath($_.FullName)) -and
        $_.FullName -notmatch '\\[^\\]+_files\\'
    }

$updates = @{}

foreach ($textFile in $textFiles) {
    $content = [System.IO.File]::ReadAllText($textFile.FullName)
    $rewritten = $content

    foreach ($candidate in $candidates) {
        $oldReference = Get-RelativeWebPath `
            -FromDirectory $textFile.DirectoryName `
            -ToFile $candidate.Chinese
        $newReference = Get-RelativeWebPath `
            -FromDirectory $textFile.DirectoryName `
            -ToFile $candidate.English

        $rewritten = Replace-StandaloneReference `
            -Content $rewritten `
            -OldReference $oldReference `
            -NewReference $newReference
        $decodedOld = [System.Uri]::UnescapeDataString($oldReference)
        $decodedNew = [System.Uri]::UnescapeDataString($newReference)
        if ($decodedOld -ne $oldReference) {
            $rewritten = Replace-StandaloneReference `
                -Content $rewritten `
                -OldReference $decodedOld `
                -NewReference $decodedNew
        }
    }

    if ($rewritten -ne $content) {
        $updates[$textFile.FullName] = $rewritten
    }
}

foreach ($entry in $updates.GetEnumerator()) {
    [System.IO.File]::WriteAllText($entry.Key, $entry.Value, $utf8NoBom)
}

$remainingReferences = New-Object System.Collections.Generic.List[string]
foreach ($textFile in $textFiles) {
    $content = if ($updates.ContainsKey($textFile.FullName)) {
        $updates[$textFile.FullName]
    } else {
        [System.IO.File]::ReadAllText($textFile.FullName)
    }

    foreach ($candidate in $candidates) {
        $oldReference = Get-RelativeWebPath `
            -FromDirectory $textFile.DirectoryName `
            -ToFile $candidate.Chinese
        if (
            (Test-StandaloneReference -Content $content -Reference $oldReference) -or
            (Test-StandaloneReference `
                -Content $content `
                -Reference ([System.Uri]::UnescapeDataString($oldReference)))
        ) {
            $remainingReferences.Add("$($textFile.FullName): $oldReference")
        }
    }
}

if ($remainingReferences.Count -gt 0) {
    throw "Translated asset references remain after rewriting:`n$($remainingReferences -join "`n")"
}

$removedBytes = 0L
foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate.Chinese -PathType Leaf) {
        Remove-Item -LiteralPath $candidate.Chinese -Force
        $removedBytes += $candidate.Bytes
    }
}

Get-ChildItem -Path $chineseRoot -Recurse -Directory |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

Write-Host (
    'Translated asset deduplication complete. Updated: {0} text file(s); removed: {1} image copy/copies; reclaimed: {2:N2} MB.' -f
    $updates.Count,
    @($candidates).Count,
    ($removedBytes / 1MB)
)
