param(
    [switch]$IncludeModel
)

$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path $PSScriptRoot -Parent
$extDir = Join-Path $releaseRoot 'extension'
$manifestPath = Join-Path $extDir 'manifest.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "找不到 manifest.json：$manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version = $manifest.version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "manifest.json 缺少 version 欄位。"
}
if ([string]::IsNullOrWhiteSpace($manifest.description)) {
    throw "manifest.json 缺少 description 欄位。"
}

# 檢查擴充功能核心檔案、圖示與內建推論環境
$requiredFiles = @(
    'manifest.json', 'background.js', 'content.js',
    'engine.html', 'engine.js', 'export-log.js',
    'pip-renderer.js', 'popup.html', 'popup.js',
    'sidepanel.html', 'sidepanel.js', 'subtitles.js',
    'data\character-names.json',
    'icons\icon16.png', 'icons\icon48.png', 'icons\icon128.png',
    'vendor\wllama\wllama.js',
    'vendor\wllama\wllama.wasm',
    'vendor\wllama\wllama-compat.wasm'
)

foreach ($relPath in $requiredFiles) {
    $fullPath = Join-Path $extDir $relPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "發布驗證失敗，缺少必備檔案：$relPath"
    }
}

$distDir = Join-Path $releaseRoot 'dist'
New-Item -ItemType Directory -Force $distDir | Out-Null

$suffix = if ($IncludeModel) { 'full' } else { 'webstore' }
$zipName = "granblue-zh-subtitle-v$version-$suffix.zip"
$zipPath = Join-Path $distDir $zipName
$stagingDir = Join-Path $distDir "_staging_$suffix"

if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

New-Item -ItemType Directory -Force $stagingDir | Out-Null

try {
    # 複製擴充功能根目錄內容（zip 根目錄即含 manifest.json，可直接上傳 Chrome Web Store）
    $coreItems = @(
        'manifest.json', 'background.js', 'content.js',
        'engine.html', 'engine.js', 'export-log.js',
        'pip-renderer.js', 'popup.html', 'popup.js',
        'sidepanel.html', 'sidepanel.js', 'subtitles.js'
    )
    foreach ($item in $coreItems) {
        Copy-Item -LiteralPath (Join-Path $extDir $item) -Destination (Join-Path $stagingDir $item) -Force
    }
    foreach ($dirName in @('data', 'icons', 'licenses', 'vendor')) {
        Copy-Item -LiteralPath (Join-Path $extDir $dirName) -Destination (Join-Path $stagingDir $dirName) -Recurse -Force
    }

    if ($IncludeModel) {
        $modelSrc = Join-Path $extDir 'model\plamo-3-translate-0.8b-Q4_K_M.gguf'
        if (-not (Test-Path -LiteralPath $modelSrc)) {
            throw "已指定 -IncludeModel，但找不到 $modelSrc。請先執行 setup-runtime.ps1。"
        }
        $stagingModel = Join-Path $stagingDir 'model'
        New-Item -ItemType Directory -Force $stagingModel | Out-Null
        Copy-Item -LiteralPath $modelSrc -Destination (Join-Path $stagingModel 'plamo-3-translate-0.8b-Q4_K_M.gguf') -Force
    }

    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Output "發布套件驗證通過並已建立：$zipPath"
} finally {
    if (Test-Path -LiteralPath $stagingDir) {
        Remove-Item -LiteralPath $stagingDir -Recurse -Force
    }
}
