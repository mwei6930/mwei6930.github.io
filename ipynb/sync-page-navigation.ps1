param(
    [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

$rootPath = (Resolve-Path -LiteralPath $Root).Path
$sharedCss = Join-Path $rootPath "blog-images.css"
$readingCss = Join-Path $rootPath "reading-toolbar.css"
$readingJs = Join-Path $rootPath "reading-toolbar.js"
$libraryOptimizer = Join-Path $rootPath "deduplicate-quarto-libs.ps1"
$translatedAssetOptimizer = Join-Path $rootPath "deduplicate-translated-assets.ps1"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$singleline = [System.Text.RegularExpressions.RegexOptions]::Singleline
$ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$regexOptions = $singleline -bor $ignoreCase

foreach ($requiredFile in @(
    $sharedCss,
    $readingCss,
    $readingJs,
    $libraryOptimizer,
    $translatedAssetOptimizer
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Shared notebook asset was not found: $requiredFile"
    }
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

function Get-ChineseText {
    param([int[]]$CodePoints)

    return ($CodePoints | ForEach-Object { [char]$_ }) -join ""
}

function Insert-BeforeHeadEnd {
    param(
        [string]$Html,
        [string]$Markup
    )

    $headEnd = $Html.IndexOf(
        "</head>",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    if ($headEnd -lt 0) {
        return $Html
    }

    return $Html.Insert($headEnd, $Markup)
}

function Get-PreambleOverviewMatch {
    param(
        [string]$Html,
        [string]$Pattern
    )

    $mainMatch = [regex]::Match(
        $Html,
        '<main\b[^>]*class="[^"]*\bcontent\b[^"]*"[^>]*>',
        $regexOptions
    )
    if (-not $mainMatch.Success) {
        return $null
    }

    $searchStart = $mainMatch.Index + $mainMatch.Length
    $sectionIndex = $Html.IndexOf(
        "<section",
        $searchStart,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $searchEnd = if ($sectionIndex -ge 0) {
        $sectionIndex
    } else {
        [Math]::Min($Html.Length, $searchStart + 5000)
    }

    if ($searchEnd -le $searchStart) {
        return $null
    }

    $preamble = $Html.Substring(
        $searchStart,
        $searchEnd - $searchStart
    )
    $match = [regex]::Match($preamble, $Pattern, $regexOptions)
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        Index = $searchStart + $match.Index
        Length = $match.Length
        Link = $match.Groups["link"].Value
    }
}

function Get-RootRelativeLanguageHref {
    param(
        [System.IO.FileInfo]$Page,
        [string]$Href
    )

    $decodedHref = [System.Net.WebUtility]::HtmlDecode($Href)
    $decodedHref = [System.Uri]::UnescapeDataString(
        ($decodedHref -split '[?#]', 2)[0]
    )

    if (
        -not $decodedHref -or
        $decodedHref -match '^[a-z][a-z0-9+.-]*:'
    ) {
        return $Href
    }

    if ($decodedHref.StartsWith("/ipynb/")) {
        return $Href
    }

    $target = $null
    if ($Page.Name.EndsWith(
        ".zh-CN.html",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        $englishName =
            $Page.Name.Substring(
                0,
                $Page.Name.Length - ".zh-CN.html".Length
            ) +
            ".html"
        $candidate = Join-Path $Page.DirectoryName $englishName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $target = (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    if (-not $target -and -not $decodedHref.StartsWith("/")) {
        $candidate = [System.IO.Path]::GetFullPath(
            (Join-Path $Page.DirectoryName $decodedHref.Replace('/', '\'))
        )
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $target = (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    if (-not $target) {
        return $Href
    }

    $rootPrefix = $rootPath.TrimEnd('\') + '\'
    if (-not $target.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $Href
    }

    $relativeTarget = $target.Substring($rootPrefix.Length)
    $encodedSegments = $relativeTarget -split '[\\/]+' |
        ForEach-Object { [System.Uri]::EscapeDataString($_) }
    return "/ipynb/" + ($encodedSegments -join "/")
}

# Keep copied notebook stylesheets aligned with the canonical stylesheet.
$cssCopies = Get-ChildItem -Path $rootPath -Recurse -Force -File -Filter "blog-images.css" |
    Where-Object {
        $relativePath = $_.FullName.Substring($rootPath.Length).TrimStart('\', '/')
        $_.FullName -ne $sharedCss -and
        $relativePath -notmatch '(^|[\\/])\.translation-work([\\/]|$)' -and
        $relativePath -notmatch '(^|[\\/])\.ipynb_checkpoints([\\/]|$)' -and
        $relativePath -notmatch '(^|[\\/])[^\\/]+_files([\\/]|$)'
    }

foreach ($copy in $cssCopies) {
    [System.IO.File]::Copy($sharedCss, $copy.FullName, $true)
}

$htmlFiles = Get-ChildItem -Path $rootPath -Recurse -File -Filter "*.html" |
    Where-Object {
        $relativePath = $_.FullName.Substring($rootPath.Length).TrimStart('\', '/')
        $relativePath -notmatch '(^|[\\/])\.translation-work([\\/]|$)' -and
        $relativePath -notmatch '(^|[\\/])\.ipynb_checkpoints([\\/]|$)' -and
        $relativePath -notmatch '(^|[\\/])[^\\/]+_files([\\/]|$)'
    }

$overviewLinkPattern =
    '<a\b[^>]*>[^<]*(?:guideline|overview|\u603B\u89C8|\u6307\u5357)[^<]*</a>'
$overviewParagraphPattern =
    '<p>\s*(?<link>' + $overviewLinkPattern + ')\s*</p>'
$navigationPattern =
    '<div class="blog-page-nav"[^>]*>.*?</div>'
$languageSwitchPattern =
    '<div class="blog-language-switch"[^>]*>.*?</div>'
$toolbarCssPattern =
    '<link\b[^>]*reading-toolbar\.css[^>]*>\s*'
$toolbarJsPattern =
    '<script\b[^>]*reading-toolbar\.js[^>]*>\s*</script>\s*'

$updated = 0
$unchanged = 0
$processed = 0

foreach ($htmlFile in $htmlFiles) {
    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)

    if (
        -not $html.Contains("<main") -or
        -not $html.Contains('id="quarto-content"')
    ) {
        continue
    }

    $processed += 1
    $original = $html
    $newline = if ($html.Contains("`r`n")) { "`r`n" } else { "`n" }

    # Normalize shared reading assets into the document head. This also removes
    # the original NLP 01 experiment's body-level include tags.
    $html = [regex]::Replace(
        $html,
        $toolbarCssPattern,
        "",
        $regexOptions
    )
    $html = [regex]::Replace(
        $html,
        $toolbarJsPattern,
        "",
        $regexOptions
    )

    if (-not $html.Contains("blog-images.css")) {
        $localCss = Join-Path $htmlFile.DirectoryName "blog-images.css"
        $cssHref = if (Test-Path -LiteralPath $localCss -PathType Leaf) {
            "blog-images.css"
        } else {
            Get-RelativeWebPath -FromDirectory $htmlFile.DirectoryName -ToFile $sharedCss
        }

        $html = Insert-BeforeHeadEnd -Html $html -Markup (
            '<link rel="stylesheet" href="' + $cssHref + '">' + $newline
        )
    }

    $readingCssHref = Get-RelativeWebPath `
        -FromDirectory $htmlFile.DirectoryName `
        -ToFile $readingCss
    $readingJsSrc = Get-RelativeWebPath `
        -FromDirectory $htmlFile.DirectoryName `
        -ToFile $readingJs
    $readingAssets =
        '<link rel="stylesheet" href="' + $readingCssHref + '">' +
        $newline +
        '<script src="' + $readingJsSrc + '" defer></script>' +
        $newline
    $html = Insert-BeforeHeadEnd -Html $html -Markup $readingAssets

    $isChinese = [regex]::IsMatch(
        $html,
        '<html\b[^>]*\blang="zh(?:-CN)?"',
        $ignoreCase
    )
    $homeLabel = if ($isChinese) {
        Get-ChineseText @(0x535A, 0x5BA2, 0x9996, 0x9875)
    } else {
        "Hexo Home"
    }
    $navigationLabel = if ($isChinese) {
        Get-ChineseText @(0x9875, 0x9762, 0x5BFC, 0x822A)
    } else {
        "Page navigation"
    }

    $languageSwitch = [regex]::Match(
        $html,
        $languageSwitchPattern,
        $regexOptions
    )
    if ($languageSwitch.Success) {
        $languageHref = [regex]::Match(
            $languageSwitch.Value,
            'href="(?<href>[^"]+)"',
            $regexOptions
        )
        if ($languageHref.Success) {
            $normalizedHref = Get-RootRelativeLanguageHref `
                -Page $htmlFile `
                -Href $languageHref.Groups["href"].Value
            if ($normalizedHref -ne $languageHref.Groups["href"].Value) {
                $normalizedSwitch =
                    $languageSwitch.Value.Substring(
                        0,
                        $languageHref.Groups["href"].Index
                    ) +
                    $normalizedHref +
                    $languageSwitch.Value.Substring(
                        $languageHref.Groups["href"].Index +
                        $languageHref.Groups["href"].Length
                    )
                $html =
                    $html.Substring(0, $languageSwitch.Index) +
                    $normalizedSwitch +
                    $html.Substring(
                        $languageSwitch.Index +
                        $languageSwitch.Length
                    )
            }
        }
    }

    $overviewLink = $null
    $existingNavigation = [regex]::Match(
        $html,
        $navigationPattern,
        $regexOptions
    )
    if ($existingNavigation.Success) {
        $existingOverview = [regex]::Match(
            $existingNavigation.Value,
            $overviewLinkPattern,
            $regexOptions
        )
        if ($existingOverview.Success) {
            $overviewLink = $existingOverview.Value
        }

        $html = $html.Remove(
            $existingNavigation.Index,
            $existingNavigation.Length
        )
    }

    $overviewParagraph = Get-PreambleOverviewMatch `
        -Html $html `
        -Pattern $overviewParagraphPattern
    if ($overviewParagraph) {
        if (-not $overviewLink) {
            $overviewLink = $overviewParagraph.Link
        }
        $html = $html.Remove(
            $overviewParagraph.Index,
            $overviewParagraph.Length
        )
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
        '</div>' +
        $newline

    $languageSwitch = [regex]::Match(
        $html,
        $languageSwitchPattern,
        $regexOptions
    )
    if ($languageSwitch.Success) {
        $insertAt = $languageSwitch.Index + $languageSwitch.Length
        $tail = [regex]::Replace(
            $html.Substring($insertAt),
            '^\s*',
            ""
        )
        $html =
            $html.Substring(0, $insertAt) +
            $navigation +
            $tail
    } else {
        $titleHeader = [regex]::Match(
            $html,
            '<header\b[^>]*id="title-block-header"[^>]*>.*?</header>',
            $regexOptions
        )
        if ($titleHeader.Success) {
            $insertAt = $titleHeader.Index + $titleHeader.Length
            $tail = [regex]::Replace(
                $html.Substring($insertAt),
                '^\s*',
                ""
            )
            $html =
                $html.Substring(0, $insertAt) +
                $navigation +
                $tail
        } else {
            $mainTag = [regex]::Match(
                $html,
                '<main\b[^>]*class="[^"]*\bcontent\b[^"]*"[^>]*>',
                $regexOptions
            )
            if ($mainTag.Success) {
                $insertAt = $mainTag.Index + $mainTag.Length
                $tail = [regex]::Replace(
                    $html.Substring($insertAt),
                    '^\s*',
                    ""
                )
                $html =
                    $html.Substring(0, $insertAt) +
                    $navigation +
                    $tail
            }
        }
    }

    if ($html -ne $original) {
        [System.IO.File]::WriteAllText(
            $htmlFile.FullName,
            $html,
            $utf8NoBom
        )
        $updated += 1
    } else {
        $unchanged += 1
    }
}

Write-Host (
    "Navigation sync complete. Processed: $processed; updated: $updated; " +
    "unchanged: $unchanged; CSS copies: $($cssCopies.Count)."
)

& $libraryOptimizer -Root $rootPath
& $translatedAssetOptimizer -Root $rootPath
