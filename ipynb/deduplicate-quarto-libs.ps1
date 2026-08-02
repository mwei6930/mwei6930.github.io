param(
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$sharedRoot = Join-Path $rootPath 'shared\quarto-libs'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$referencePattern = '(?<resource>[^"''<>]+?_files)/libs/(?<package>[^/"''<>]+)/'
$referenceRegex = New-Object System.Text.RegularExpressions.Regex(
    $referencePattern,
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$sharedBytesBefore = if (Test-Path -LiteralPath $sharedRoot -PathType Container) {
    [long]((
        Get-ChildItem -LiteralPath $sharedRoot -Recurse -File |
            Measure-Object -Property Length -Sum
    ).Sum)
} else {
    0L
}

function Get-NormalPathKey {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
}

function Get-DirectorySignature {
    param([string]$Directory)

    $entries = Get-ChildItem -LiteralPath $Directory -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($Directory.Length).TrimStart('\').Replace('\', '/')
            $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            "$relativePath`:$fileHash"
        }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Get-RelativeWebPath {
    param(
        [string]$FromDirectory,
        [string]$ToDirectory
    )

    $fromPath = [System.IO.Path]::GetFullPath($FromDirectory).TrimEnd('\') + '\'
    $toPath = [System.IO.Path]::GetFullPath($ToDirectory).TrimEnd('\') + '\'
    $fromUri = New-Object System.Uri($fromPath)
    $toUri = New-Object System.Uri($toPath)
    return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).TrimEnd('/')
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $relativePath = $_.FullName.Substring($Source.Length).TrimStart('\')
        $targetPath = Join-Path $Destination $relativePath
        $targetDirectory = Split-Path -Parent $targetPath
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
    }
}

$packageDirectories = Get-ChildItem -Path $rootPath -Recurse -Directory -Force |
    Where-Object {
        $_.Parent -and
        $_.Parent.Name -eq 'libs' -and
        $_.FullName -notmatch '\\.translation-work\\' -and
        $_.FullName -notmatch '\\.ipynb_checkpoints\\' -and
        $_.FullName -notmatch '\\shared\\quarto-libs\\'
    }

if (-not $packageDirectories) {
    Write-Host 'Quarto library deduplication complete. No local library copies found.'
    exit 0
}

$records = foreach ($directory in $packageDirectories) {
    [PSCustomObject]@{
        Directory = $directory.FullName
        Package = $directory.Name
        Signature = Get-DirectorySignature -Directory $directory.FullName
        Bytes = [long]((
            Get-ChildItem -LiteralPath $directory.FullName -Recurse -File |
                Measure-Object -Property Length -Sum
        ).Sum)
    }
}

New-Item -ItemType Directory -Path $sharedRoot -Force | Out-Null
$packageMap = @{}
$sharedTargets = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

foreach ($packageName in ($records.Package | Sort-Object -Unique)) {
    $packageRecords = @($records | Where-Object { $_.Package -eq $packageName })
    $signatures = @($packageRecords.Signature | Sort-Object -Unique)

    foreach ($signature in $signatures) {
        $matchingRecords = @($packageRecords | Where-Object { $_.Signature -eq $signature })
        $targetName = if ($signatures.Count -eq 1) {
            $packageName
        } else {
            '{0}-{1}' -f $packageName, $signature.Substring(0, 12).ToLowerInvariant()
        }
        $targetDirectory = Join-Path $sharedRoot $targetName

        if (Test-Path -LiteralPath $targetDirectory -PathType Container) {
            $targetSignature = Get-DirectorySignature -Directory $targetDirectory
            if ($targetSignature -ne $signature) {
                Remove-Item -LiteralPath $targetDirectory -Recurse -Force
                Copy-DirectoryContents -Source $matchingRecords[0].Directory -Destination $targetDirectory
            }
        } else {
            Copy-DirectoryContents -Source $matchingRecords[0].Directory -Destination $targetDirectory
        }

        $null = $sharedTargets.Add($targetDirectory)
        foreach ($record in $matchingRecords) {
            $packageMap[(Get-NormalPathKey -Path $record.Directory)] = $targetDirectory
        }
    }
}

$htmlFiles = Get-ChildItem -Path $rootPath -Recurse -File -Filter '*.html' |
    Where-Object {
        $_.FullName -notmatch '\\.translation-work\\' -and
        $_.FullName -notmatch '\\.ipynb_checkpoints\\' -and
        $_.FullName -notmatch '\\[^\\]+_files\\' -and
        $_.FullName -notmatch '\\shared\\'
    }

$updates = @{}
$unresolved = New-Object System.Collections.Generic.List[string]

foreach ($htmlFile in $htmlFiles) {
    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)
    if (-not $referenceRegex.IsMatch($html)) {
        continue
    }

    $rewritten = $referenceRegex.Replace(
        $html,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)

            $resourcePath = [System.Net.WebUtility]::HtmlDecode($match.Groups['resource'].Value)
            $resourcePath = [System.Uri]::UnescapeDataString($resourcePath).Replace('/', '\')
            $packageName = $match.Groups['package'].Value
            $localPackage = [System.IO.Path]::GetFullPath(
                (Join-Path $htmlFile.DirectoryName (Join-Path $resourcePath (Join-Path 'libs' $packageName)))
            )
            $key = Get-NormalPathKey -Path $localPackage

            if (-not $packageMap.ContainsKey($key)) {
                $unresolved.Add("$($htmlFile.FullName): $($match.Value)")
                return $match.Value
            }

            $relativeTarget = Get-RelativeWebPath `
                -FromDirectory $htmlFile.DirectoryName `
                -ToDirectory $packageMap[$key]
            return $relativeTarget + '/'
        }
    )

    if ($referenceRegex.IsMatch($rewritten)) {
        $unresolved.Add("$($htmlFile.FullName): unresolved local library reference")
    }

    if ($rewritten -ne $html) {
        $updates[$htmlFile.FullName] = $rewritten
    }
}

if ($unresolved.Count -gt 0) {
    throw "Quarto library references could not be resolved:`n$($unresolved -join "`n")"
}

foreach ($entry in $updates.GetEnumerator()) {
    [System.IO.File]::WriteAllText($entry.Key, $entry.Value, $utf8NoBom)
}

$localBytes = [long](($records.Bytes | Measure-Object -Sum).Sum)
$libraryDirectories = $packageDirectories |
    ForEach-Object { $_.Parent.FullName } |
    Sort-Object -Unique

foreach ($libraryDirectory in $libraryDirectories) {
    if (Test-Path -LiteralPath $libraryDirectory -PathType Container) {
        Remove-Item -LiteralPath $libraryDirectory -Recurse -Force
        $resourceDirectory = Split-Path -Parent $libraryDirectory
        if (
            (Test-Path -LiteralPath $resourceDirectory -PathType Container) -and
            -not (Get-ChildItem -LiteralPath $resourceDirectory -Force | Select-Object -First 1)
        ) {
            Remove-Item -LiteralPath $resourceDirectory -Force
        }
    }
}

$sharedBytes = [long]((
    Get-ChildItem -LiteralPath $sharedRoot -Recurse -File |
        Measure-Object -Property Length -Sum
).Sum)
$newSharedBytes = [Math]::Max(0L, $sharedBytes - $sharedBytesBefore)

Write-Host (
    'Quarto library deduplication complete. Updated: {0} HTML file(s); reclaimed: {1:N2} MB.' -f
    $updates.Count,
    (($localBytes - $newSharedBytes) / 1MB)
)
