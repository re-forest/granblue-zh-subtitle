param(
    [string]$SourceDir = "",
    [string]$ModelUrl = "https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/main/plamo-3-translate-0.8b-Q4_K_M.gguf"
)

$ErrorActionPreference = 'Stop'

$releaseRoot = Split-Path $PSScriptRoot -Parent
$targetExtension = Join-Path $releaseRoot 'extension'
$targetModelDir = Join-Path $targetExtension 'model'
$modelFileName = 'plamo-3-translate-0.8b-Q4_K_M.gguf'
$targetModel = Join-Path $targetModelDir $modelFileName

New-Item -ItemType Directory -Force $targetModelDir | Out-Null

if ((Test-Path -LiteralPath $targetModel) -and (Get-Item -LiteralPath $targetModel).Length -gt 500000000) {
    Write-Output "模型檔案已就緒：$targetModel"
    Write-Output "完成！現在可於 Chrome 載入未封裝項目：$targetExtension"
    exit 0
}

$parentExt = Join-Path (Split-Path $releaseRoot -Parent) 'extension'
$localCache = Join-Path $env:LOCALAPPDATA 'GBF-Translation-Bench'

$modelCandidates = @()
if ($SourceDir) {
    $modelCandidates += @(
        (Join-Path $SourceDir $modelFileName),
        (Join-Path $SourceDir "model\$modelFileName"),
        (Join-Path $SourceDir "extension\model\$modelFileName")
    )
}
$modelCandidates += @(
    (Join-Path $parentExt "model\$modelFileName"),
    (Join-Path $localCache $modelFileName)
)

$modelSource = $modelCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

$tempFile = "$targetModel.part"
if ($modelSource) {
    Write-Output "正在從本機複製模型檔案（約 547 MB）：$modelSource -> $targetModel"
    Copy-Item -LiteralPath $modelSource -Destination $tempFile -Force
    Move-Item -LiteralPath $tempFile -Destination $targetModel -Force
} else {
    Write-Output "本機未找到現成模型，正在從 Hugging Face 下載 $modelFileName（約 547 MB）..."
    & curl.exe -L --fail --retry 3 -o $tempFile $ModelUrl
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
        throw "模型下載失敗，請檢查網路連線或手動從 $ModelUrl 下載後放入 $targetModelDir。"
    }
    Move-Item -LiteralPath $tempFile -Destination $targetModel -Force
}

Write-Output "完成！現在可於 Chrome 載入未封裝項目：$targetExtension"
