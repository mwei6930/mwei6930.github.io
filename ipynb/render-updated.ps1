param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$quarto = Get-Command quarto -ErrorAction SilentlyContinue

if (-not $quarto) {
    throw "quarto was not found in PATH. Install Quarto or add it to PATH before running this script."
}

$notebooks = Get-ChildItem -Path $root -Recurse -File -Filter *.ipynb |
    Where-Object {
        $_.FullName -notmatch "\\.ipynb_checkpoints\\" -and
        $_.Name -notlike "*-full.ipynb"
    } |
    Sort-Object FullName

$rendered = 0
$skipped = 0

foreach ($notebook in $notebooks) {
    $htmlPath = [System.IO.Path]::ChangeExtension($notebook.FullName, ".html")
    $html = Get-Item -LiteralPath $htmlPath -ErrorAction SilentlyContinue

    $needsRender = $Force -or
        (-not $html) -or
        ($notebook.LastWriteTime -gt $html.LastWriteTime)

    if (-not $needsRender) {
        Write-Host "[skip]   $($notebook.FullName)"
        $skipped += 1
        continue
    }

    if ($Force) {
        $reason = "force"
    } elseif (-not $html) {
        $reason = "missing html"
    } else {
        $reason = "notebook newer"
    }

    Write-Host "[render] $($notebook.FullName) ($reason)"
    & quarto render $notebook.FullName --to html

    if ($LASTEXITCODE -ne 0) {
        throw "quarto render failed for $($notebook.FullName)"
    }

    $rendered += 1
}

Write-Host ""
Write-Host "Done. Rendered: $rendered; skipped: $skipped."
