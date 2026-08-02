param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$quarto = Get-Command quarto -ErrorAction SilentlyContinue
$sharedCss = Join-Path $root "blog-images.css"
$lightboxFilter = Join-Path $root "lightbox-all.lua"
$navigationSync = Join-Path $root "sync-page-navigation.ps1"
$readingCss = Join-Path $root "reading-toolbar.css"
$readingJs = Join-Path $root "reading-toolbar.js"

if (-not $quarto) {
    throw "quarto was not found in PATH. Install Quarto or add it to PATH before running this script."
}

if (-not (Test-Path -LiteralPath $sharedCss -PathType Leaf)) {
    throw "Shared notebook stylesheet was not found: $sharedCss"
}

if (-not (Test-Path -LiteralPath $lightboxFilter -PathType Leaf)) {
    throw "Shared Lightbox filter was not found: $lightboxFilter"
}

if (-not (Test-Path -LiteralPath $navigationSync -PathType Leaf)) {
    throw "Navigation sync script was not found: $navigationSync"
}

if (-not (Test-Path -LiteralPath $readingCss -PathType Leaf)) {
    throw "Shared reading-navigation stylesheet was not found: $readingCss"
}

if (-not (Test-Path -LiteralPath $readingJs -PathType Leaf)) {
    throw "Shared reading-navigation script was not found: $readingJs"
}

$notebooks = Get-ChildItem -Path $root -Recurse -File -Filter *.ipynb |
    Where-Object {
        $_.FullName -notmatch "\\.ipynb_checkpoints\\" -and
        $_.FullName -notmatch "\\.translation-work\\" -and
        $_.Name -notlike "*.zh-CN.ipynb" -and
        $_.Name -notlike "*-full.ipynb"
    } |
    Sort-Object FullName

$rendered = 0
$skipped = 0

function ConvertTo-YamlSafeTitleLine {
    param([string]$Line)

    if ($Line -notmatch '^title:\s*(.+)$') {
        return $Line
    }

    $title = $Matches[1].Trim()

    if (
        ($title.StartsWith('"') -and $title.EndsWith('"')) -or
        ($title.StartsWith("'") -and $title.EndsWith("'"))
    ) {
        return $Line
    }

    if ($title.Contains(":")) {
        $escaped = $title.Replace('\', '\\').Replace('"', '\"')
        return "title: `"$escaped`""
    }

    return $Line
}

function Repair-NotebookYamlTitle {
    param([System.IO.FileInfo]$Notebook)

    $json = Get-Content -LiteralPath $Notebook.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not $json.cells -or $json.cells.Count -eq 0) {
        return $false
    }

    $firstCell = $json.cells[0]

    if ($firstCell.cell_type -ne "raw" -or -not $firstCell.source) {
        return $false
    }

    $changed = $false
    $newSource = @()

    foreach ($line in $firstCell.source) {
        $newline = ""
        if ($line.EndsWith("`r`n")) {
            $newline = "`r`n"
            $body = $line.Substring(0, $line.Length - 2)
        } elseif ($line.EndsWith("`n")) {
            $newline = "`n"
            $body = $line.Substring(0, $line.Length - 1)
        } else {
            $body = $line
        }

        $safeBody = ConvertTo-YamlSafeTitleLine -Line $body
        if ($safeBody -ne $body) {
            $changed = $true
        }

        $newSource += "$safeBody$newline"
    }

    if ($changed) {
        $firstCell.source = $newSource
        $jsonText = $json | ConvertTo-Json -Depth 100
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Notebook.FullName, $jsonText, $utf8NoBom)
        Write-Host "[fix]    YAML title quoted in $($Notebook.FullName)"
    }

    return $changed
}

foreach ($notebook in $notebooks) {
    $titleWasRepaired = Repair-NotebookYamlTitle -Notebook $notebook
    $htmlPath = [System.IO.Path]::ChangeExtension($notebook.FullName, ".html")
    $html = Get-Item -LiteralPath $htmlPath -ErrorAction SilentlyContinue

    $needsRender = $Force -or
        $titleWasRepaired -or
        (-not $html) -or
        ($notebook.LastWriteTime -gt $html.LastWriteTime)

    if (-not $needsRender) {
        Write-Host "[skip]   $($notebook.FullName)"
        $skipped += 1
        continue
    }

    if ($Force) {
        $reason = "force"
    } elseif ($titleWasRepaired) {
        $reason = "yaml title repaired"
    } elseif (-not $html) {
        $reason = "missing html"
    } else {
        $reason = "notebook newer"
    }

    $relativeDirectory = $notebook.DirectoryName.Substring($root.Length).TrimStart('\', '/')
    $directoryDepth = 0
    if ($relativeDirectory) {
        $directoryDepth = ($relativeDirectory -split '[\\/]').Count
    }

    $rootPathParts = @()
    for ($level = 0; $level -lt $directoryDepth; $level += 1) {
        $rootPathParts += ".."
    }
    $relativeCssPath = ($rootPathParts + "blog-images.css") -join "/"
    $relativeLightboxFilterPath = ($rootPathParts + "lightbox-all.lua") -join "/"

    Write-Host "[render] $($notebook.FullName) ($reason)"

    Push-Location -LiteralPath $notebook.DirectoryName
    try {
        & quarto render $notebook.Name --to html -M lightbox:true --css $relativeCssPath --lua-filter $relativeLightboxFilterPath
        $renderExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($renderExitCode -ne 0) {
        throw "quarto render failed for $($notebook.FullName)"
    }

    $rendered += 1
}

& $navigationSync -Root $root

Write-Host ""
Write-Host "Done. Rendered: $rendered; skipped: $skipped."
