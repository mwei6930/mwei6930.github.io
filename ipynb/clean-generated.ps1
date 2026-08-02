[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

$notebookRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $notebookRoot "..")).Path

function Assert-PathInsideSource {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $sourceRoot.TrimEnd('\') + '\'
    if (
        $fullPath -ne $sourceRoot -and
        -not $fullPath.StartsWith(
            $prefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Refusing to remove a path outside the source directory: $fullPath"
    }

    return $fullPath
}

function Get-PathBytes {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-Item -LiteralPath $Path).Length
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        $measurement = Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
            Measure-Object -Property Length -Sum
        return [long]($measurement.Sum)
    }

    return 0
}

$directoryTargets = New-Object System.Collections.Generic.List[string]

Get-ChildItem -Path $sourceRoot -Recurse -Directory -Force |
    Where-Object { $_.Name -in @('.ipynb_checkpoints', '__pycache__') } |
    ForEach-Object { $directoryTargets.Add($_.FullName) }

Get-ChildItem -Path $notebookRoot -Recurse -Directory -Force |
    Where-Object {
        ($_.Name -eq 'stage' -and $_.Parent.Name -eq '.translation-work') -or
        ($_.Parent.Name -eq '.translation-work' -and $_.Name -like 'external-image-review-*') -or
        ($_.Parent.Name -eq '.translation-work' -and $_.Name -eq 'screenshots')
    } |
    ForEach-Object { $directoryTargets.Add($_.FullName) }

$fileTargets = New-Object System.Collections.Generic.List[string]

# Remove only intermediate Chinese HTML when a published counterpart exists.
Get-ChildItem -Path $notebookRoot -Recurse -File -Filter '*.zh-CN.html' |
    Where-Object {
        $_.FullName -notmatch '\\zh-CN\\' -and
        $_.FullName -notmatch '\\.translation-work\\'
    } |
    ForEach-Object {
        $relativeDirectory = $_.DirectoryName.Substring($notebookRoot.Length).TrimStart('\', '/')
        $publishedDirectory = Join-Path (Join-Path $notebookRoot 'zh-CN') $relativeDirectory
        $publishedName = $_.Name -replace '\.zh-CN\.html$', '.html'
        $publishedPath = Join-Path $publishedDirectory $publishedName

        if (Test-Path -LiteralPath $publishedPath -PathType Leaf) {
            $fileTargets.Add($_.FullName)
            $resourceDirectory = Join-Path $_.DirectoryName ($_.BaseName + '_files')
            if (Test-Path -LiteralPath $resourceDirectory -PathType Container) {
                $directoryTargets.Add($resourceDirectory)
            }
        }
    }

# Keep only top-level directory targets so nested caches are not removed twice.
$selectedDirectories = New-Object System.Collections.Generic.List[string]
$normalizedDirectories = $directoryTargets |
    ForEach-Object { Assert-PathInsideSource -Path $_ } |
    Sort-Object Length, @{ Expression = { $_ } } -Unique

foreach ($candidate in $normalizedDirectories) {
    $candidatePrefix = $candidate.TrimEnd('\') + '\'
    $covered = $false
    foreach ($selected in $selectedDirectories) {
        $selectedPrefix = $selected.TrimEnd('\') + '\'
        if ($candidate.StartsWith($selectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $covered = $true
            break
        }
    }

    if (-not $covered) {
        $selectedDirectories.Add($candidate)
    }
}

$removedBytes = 0L
$removedItems = 0

foreach ($path in $selectedDirectories) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        continue
    }

    $bytes = Get-PathBytes -Path $path
    if ($PSCmdlet.ShouldProcess($path, 'Remove generated directory')) {
        Remove-Item -LiteralPath $path -Recurse -Force
        $removedBytes += $bytes
        $removedItems += 1
        Write-Host "[remove] $path"
    }
}

foreach ($path in ($fileTargets | Sort-Object -Unique)) {
    $safePath = Assert-PathInsideSource -Path $path
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) {
        continue
    }

    $bytes = Get-PathBytes -Path $safePath
    if ($PSCmdlet.ShouldProcess($safePath, 'Remove intermediate translated HTML')) {
        Remove-Item -LiteralPath $safePath -Force
        $removedBytes += $bytes
        $removedItems += 1
        Write-Host "[remove] $safePath"
    }
}

Write-Host ""
Write-Host (
    'Generated cleanup complete. Removed: {0} item(s); reclaimed: {1:N2} MB.' -f
    $removedItems,
    ($removedBytes / 1MB)
)

