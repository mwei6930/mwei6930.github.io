param(
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$sharedCss = Join-Path $rootPath "blog-images.css"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$regexOptions = [System.Text.RegularExpressions.RegexOptions]::Singleline

if (-not (Test-Path -LiteralPath $sharedCss -PathType Leaf)) {
    throw "Shared notebook stylesheet was not found: $sharedCss"
}

function Get-RelativeWebPath {
    param(
        [string]$FromDirectory,
        [string]$ToFile
    )

    $directoryPath = (Resolve-Path -LiteralPath $FromDirectory).Path.TrimEnd('\') + '\'
    $filePath = (Resolve-Path -LiteralPath $ToFile).Path
    $directoryUri = New-Object System.Uri($directoryPath)
    $fileUri = New-Object System.Uri($filePath)
    return [System.Uri]::UnescapeDataString(
        $directoryUri.MakeRelativeUri($fileUri).ToString()
    )
}

# Keep every copied stylesheet aligned with the canonical notebook stylesheet.
$cssCopies = Get-ChildItem -Path $rootPath -Recurse -Force -File -Filter "blog-images.css" |
    Where-Object { $_.FullName -ne $sharedCss }

foreach ($copy in $cssCopies) {
    [System.IO.File]::Copy($sharedCss, $copy.FullName, $true)
}

$htmlFiles = Get-ChildItem -Path $rootPath -Recurse -File -Filter "*.html" |
    Where-Object {
        $relativePath = $_.FullName.Substring($rootPath.Length).TrimStart('\', '/')
        $relativePath -notmatch '(^|[\\/])\.translation-work([\\/]|$)' -and
        $relativePath -notmatch '(^|[\\/])[^\\/]+_files([\\/]|$)'
    }

$updated = 0
$unchanged = 0

foreach ($htmlFile in $htmlFiles) {
    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)

    if (-not $html.Contains('class="blog-language-switch"')) {
        continue
    }

    $original = $html
    $newline = if ($html.Contains("`r`n")) { "`r`n" } else { "`n" }

    if (-not $html.Contains("blog-images.css")) {
        $localCss = Join-Path $htmlFile.DirectoryName "blog-images.css"
        $cssHref = if (Test-Path -LiteralPath $localCss -PathType Leaf) {
            "blog-images.css"
        } else {
            Get-RelativeWebPath -FromDirectory $htmlFile.DirectoryName -ToFile $sharedCss
        }

        $stylesheet = '<link rel="stylesheet" href="' + $cssHref + '">'
        $html = [regex]::Replace(
            $html,
            '</head>',
            $stylesheet + $newline + '</head>',
            1
        )
    }

    $switchMatch = [regex]::Match(
        $html,
        '<div class="blog-language-switch"[^>]*>.*?</div>',
        $regexOptions
    )

    if (-not $switchMatch.Success) {
        continue
    }

    $tailStart = $switchMatch.Index + $switchMatch.Length
    $tail = $html.Substring($tailStart)
    $existingNavigation = [regex]::Match(
        $tail,
        '^\s*<div class="blog-page-nav"[^>]*>.*?</div>',
        $regexOptions
    )

    $isChinese = [regex]::IsMatch(
        $html,
        '<html\b[^>]*\blang="zh(?:-CN)?"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $homeLabel = if ($isChinese) {
        @([char]0x535A, [char]0x5BA2, [char]0x9996, [char]0x9875) -join ""
    } else {
        "Hexo Home"
    }
    $navigationLabel = if ($isChinese) {
        @([char]0x9875, [char]0x9762, [char]0x5BFC, [char]0x822A) -join ""
    } else {
        "Page navigation"
    }
    $overviewPattern =
        '<a\b[^>]*>[^<]*(?:guideline|overview|\u603B\u89C8|\u6307\u5357)[^<]*</a>'
    $overviewLink = $null
    $consumed = 0

    if ($existingNavigation.Success) {
        $existingOverview = [regex]::Match(
            $existingNavigation.Value,
            $overviewPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($existingOverview.Success) {
            $overviewLink = $existingOverview.Value
        }
        $consumed = $existingNavigation.Length
    }

    $tailAfterNavigation = $tail.Substring($consumed)
    $overviewMatch = [regex]::Match(
        $tailAfterNavigation,
        '^\s*<p>\s*(?<link>' + $overviewPattern + ')\s*</p>',
        $regexOptions -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($overviewMatch.Success) {
        if (-not $overviewLink) {
            $overviewLink = $overviewMatch.Groups["link"].Value
        }
        $consumed += $overviewMatch.Length
    }

    $navigationContent = '<a href="/">' + $homeLabel + '</a>'
    if ($overviewLink) {
        $navigationContent +=
            ' <span class="blog-page-nav-separator" aria-hidden="true">/</span> ' +
            $overviewLink
    }

    $navigation =
        $newline +
        '<div class="blog-page-nav" aria-label="' + $navigationLabel + '">' +
        $newline +
        $navigationContent +
        $newline +
        '</div>'

    $html =
        $html.Substring(0, $tailStart) +
        $navigation +
        $tail.Substring($consumed)

    if ($html -ne $original) {
        [System.IO.File]::WriteAllText($htmlFile.FullName, $html, $utf8NoBom)
        $updated += 1
    } else {
        $unchanged += 1
    }
}

Write-Host "Navigation sync complete. Updated: $updated; unchanged: $unchanged; CSS copies: $($cssCopies.Count)."
