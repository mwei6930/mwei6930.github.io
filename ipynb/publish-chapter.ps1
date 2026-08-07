param(
    [Parameter(Mandatory = $true)]
    [string]$Notebook,
    [switch]$EnglishOnly,
    [switch]$NoRender,
    [switch]$SkipCode
)

$ErrorActionPreference = 'Stop'

$scriptRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$validator = Join-Path $scriptRoot 'validate-bilingual-notebook.py'
$navigationSync = Join-Path $scriptRoot 'sync-page-navigation.ps1'
$sharedCss = Join-Path $scriptRoot 'blog-images.css'
$lightboxFilter = Join-Path $scriptRoot 'lightbox-all.lua'

function Assert-PathInsideRoot {
    param([string]$Candidate)

    $fullPath = [System.IO.Path]::GetFullPath($Candidate)
    $rootPrefix = $scriptRoot.TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Notebook must be inside $scriptRoot"
    }
    return $fullPath
}

function Resolve-NotebookPath {
    param([string]$RequestedPath)

    $candidates = if ([System.IO.Path]::IsPathRooted($RequestedPath)) {
        @($RequestedPath)
    } else {
        @(
            (Join-Path (Get-Location).Path $RequestedPath),
            (Join-Path $scriptRoot $RequestedPath)
        )
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Assert-PathInsideRoot -Candidate (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Notebook was not found: $RequestedPath"
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
    return [System.Uri]::UnescapeDataString(
        $fromUri.MakeRelativeUri($toUri).ToString()
    )
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force |
            Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    }
}

function Copy-ReferencedAssets {
    param(
        [string]$SourceNotebook,
        [string]$DestinationDirectory
    )

    $json = Get-Content -LiteralPath $SourceNotebook -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $content = ($json.cells | ForEach-Object {
        if ($_.source -is [System.Array]) {
            $_.source -join ''
        } else {
            [string]$_.source
        }
    }) -join [Environment]::NewLine

    $references = [regex]::Matches(
        $content,
        '(?:\(|src=["''])(?<path>assets/[^)"''\s>]+)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    ) | ForEach-Object {
        [System.Uri]::UnescapeDataString($_.Groups['path'].Value)
    } | Sort-Object -Unique

    $sourceDirectory = Split-Path -Parent $SourceNotebook
    foreach ($reference in $references) {
        $relativePath = $reference.Replace('/', '\')
        $sourceAsset = [System.IO.Path]::GetFullPath(
            (Join-Path $sourceDirectory $relativePath)
        )
        $sourcePrefix = $sourceDirectory.TrimEnd('\') + '\'
        if (-not $sourceAsset.StartsWith(
            $sourcePrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Asset path escaped the chapter directory: $reference"
        }
        if (-not (Test-Path -LiteralPath $sourceAsset -PathType Leaf)) {
            throw "Referenced asset was not found: $sourceAsset"
        }

        $destination = Join-Path $DestinationDirectory $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force |
            Out-Null
        Copy-Item -LiteralPath $sourceAsset -Destination $destination -Force
    }
}

function Invoke-SourceValidation {
    param(
        [string]$EnglishPath,
        [string]$ChinesePath,
        [switch]$IncludeHtml,
        [switch]$DoNotExecute,
        [string]$EnglishHtml,
        [string]$ChineseHtml
    )

    $arguments = @($validator, '--english', $EnglishPath)
    if ($ChinesePath) {
        $arguments += @('--chinese', $ChinesePath)
    }
    if (-not $SkipCode -and -not $DoNotExecute) {
        $arguments += '--execute-code'
    }
    if (-not $ChinesePath) {
        $arguments += '--allow-monolingual'
    }
    if ($IncludeHtml) {
        $arguments += @('--english-html', $EnglishHtml)
        if ($ChineseHtml) {
            $arguments += @('--chinese-html', $ChineseHtml)
        }
    }

    & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Chapter validation failed.'
    }
}

function Invoke-Quarto {
    param(
        [string]$SourcePath,
        [string]$OutputName,
        [string]$OutputDirectory
    )

    $sourceDirectory = Split-Path -Parent $SourcePath
    $sourceName = Split-Path -Leaf $SourcePath
    $relativeCss = Get-RelativeWebPath -FromDirectory $sourceDirectory -ToFile $sharedCss
    $relativeFilter = Get-RelativeWebPath -FromDirectory $sourceDirectory -ToFile $lightboxFilter

    $arguments = @('render', $sourceName, '--to', 'html')
    if ($OutputName) {
        $arguments += @('--output', $OutputName)
    }
    if ($OutputDirectory) {
        $arguments += @('--output-dir', $OutputDirectory)
    }
    $arguments += @(
        '-M', 'lightbox:true',
        '--css', $relativeCss,
        '--lua-filter', $relativeFilter
    )

    Push-Location -LiteralPath $sourceDirectory
    try {
        $previousErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $quartoOutput = & quarto @arguments 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorPreference
        }
        if ($exitCode -ne 0) {
            $errorSummary = $quartoOutput | Where-Object {
                [string]$_ -match 'ERROR:|PermissionDenied'
            } | Select-Object -First 3
            if (-not $errorSummary) {
                $errorSummary = $quartoOutput | Select-Object -Last 8
            }
            $errorSummary | ForEach-Object {
                Write-Host $_
            }
        }
        return [int]$exitCode
    } finally {
        Pop-Location
    }
}

foreach ($required in @($validator, $navigationSync, $sharedCss, $lightboxFilter)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required publishing file was not found: $required"
    }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'python was not found in PATH.'
}
if (-not $NoRender -and -not (Get-Command quarto -ErrorAction SilentlyContinue)) {
    throw 'quarto was not found in PATH.'
}

$englishPath = Resolve-NotebookPath -RequestedPath $Notebook
$englishFile = Get-Item -LiteralPath $englishPath
if ($englishFile.Name.EndsWith(
    '.zh-CN.ipynb',
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Pass the English notebook path, not the .zh-CN notebook.'
}

$chapterDirectory = $englishFile.DirectoryName
$stem = [System.IO.Path]::GetFileNameWithoutExtension($englishFile.Name)
$englishHtml = Join-Path $chapterDirectory "$stem.html"
$chinesePath = Join-Path $chapterDirectory "$stem.zh-CN.ipynb"

if ($EnglishOnly) {
    $chinesePath = $null
} elseif (-not (Test-Path -LiteralPath $chinesePath -PathType Leaf)) {
    throw (
        "Chinese notebook is missing: $chinesePath. " +
        'Finish and approve the English source, then create the manual translation; ' +
        'or use -EnglishOnly.'
    )
}

Write-Host '[validate] source'
Invoke-SourceValidation -EnglishPath $englishPath -ChinesePath $chinesePath

if ($NoRender) {
    Write-Host 'Source gate complete. Rendering intentionally skipped.'
    exit 0
}

$relativeDirectory = $chapterDirectory.Substring($scriptRoot.Length).TrimStart('\')
$chineseDirectory = if ($relativeDirectory) {
    Join-Path (Join-Path $scriptRoot 'zh-CN') $relativeDirectory
} else {
    Join-Path $scriptRoot 'zh-CN'
}
$chineseHtml = if ($chinesePath) {
    Join-Path $chineseDirectory "$stem.html"
} else {
    $null
}

if ($chinesePath) {
    New-Item -ItemType Directory -Path $chineseDirectory -Force | Out-Null
    $renderStarted = Get-Date
    Write-Host '[render] Chinese'
    $chineseExit = Invoke-Quarto -SourcePath $chinesePath -OutputName "$stem.html" -OutputDirectory $chineseDirectory

    $freshChineseHtml =
        (Test-Path -LiteralPath $chineseHtml -PathType Leaf) -and
        ((Get-Item -LiteralPath $chineseHtml).LastWriteTime -ge $renderStarted.AddSeconds(-2))
    if ($chineseExit -ne 0 -and -not $freshChineseHtml) {
        throw 'Chinese Quarto render failed before producing a fresh HTML file.'
    }
    if ($chineseExit -ne 0) {
        Write-Host '[warn] Chinese HTML was created; repairing the known Windows resource move.'
    }

    $chineseStem = [System.IO.Path]::GetFileNameWithoutExtension($chinesePath)
    $intermediateResources = Join-Path $chapterDirectory ($chineseStem + '_files')
    if (Test-Path -LiteralPath $intermediateResources -PathType Container) {
        $publishedResources = Join-Path $chineseDirectory ($chineseStem + '_files')
        Copy-DirectoryContents -Source $intermediateResources -Destination $publishedResources
        $safeIntermediate = Assert-PathInsideRoot -Candidate $intermediateResources
        Remove-Item -LiteralPath $safeIntermediate -Recurse -Force
    }
    Copy-ReferencedAssets -SourceNotebook $chinesePath -DestinationDirectory $chineseDirectory
}

# Render English last because the Chinese cross-directory render can move the
# temporary English-named output from the source directory on Windows.
Write-Host '[render] English'
$englishExit = Invoke-Quarto -SourcePath $englishPath
if ($englishExit -ne 0 -or -not (Test-Path -LiteralPath $englishHtml -PathType Leaf)) {
    throw 'English Quarto render failed.'
}

$pages = @($englishHtml)
if ($chineseHtml) {
    $pages += $chineseHtml
}

Write-Host '[sync] targeted navigation'
& $navigationSync -Root $scriptRoot -Path $pages
if ($LASTEXITCODE -ne 0) {
    throw 'Targeted navigation synchronization failed.'
}

Write-Host '[validate] rendered output'
Invoke-SourceValidation -EnglishPath $englishPath -ChinesePath $chinesePath -IncludeHtml -DoNotExecute -EnglishHtml $englishHtml -ChineseHtml $chineseHtml

Write-Host (
    'Publish complete: ' +
    $englishFile.FullName.Substring($scriptRoot.Length).TrimStart('\')
)
