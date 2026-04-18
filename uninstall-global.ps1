# uninstall-global.ps1 — 从用户级 NODE_OPTIONS 里移除 intercept.cjs 的 --require

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$InterceptPath = Join-Path $Root 'intercept.cjs'
$Flag = "--require=$InterceptPath"

$existing = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " node_helper V3 · 全局卸载" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "现有 NODE_OPTIONS (User):"
Write-Host "  $existing"
Write-Host ""

if (-not $existing) {
    Write-Host "[=] NODE_OPTIONS 已经为空,无事可做" -ForegroundColor Green
    exit 0
}

if (-not $existing.Contains($Flag)) {
    Write-Host "[=] NODE_OPTIONS 里没有 intercept.cjs 的 --require,无事可做" -ForegroundColor Green
    exit 0
}

# 移除 $Flag(可能前面或后面还有空格)
$new = ($existing -replace [regex]::Escape($Flag), '').Trim()
$new = $new -replace '  +', ' '  # 压缩多余空格

if ([string]::IsNullOrWhiteSpace($new)) {
    # 清空变量
    & setx NODE_OPTIONS "" | Out-Null
    # setx "" 其实留个空字符串;想彻底清可用 REG 删除键
    & reg delete "HKCU\Environment" /v NODE_OPTIONS /f 2>$null | Out-Null
    Write-Host "[✓] NODE_OPTIONS 已完全清除" -ForegroundColor Green
} else {
    & setx NODE_OPTIONS "$new" | Out-Null
    Write-Host "[✓] 已从 NODE_OPTIONS 移除 intercept.cjs,保留其它:" -ForegroundColor Green
    Write-Host "    $new"
}

Write-Host ""
Write-Host "注意:setx 只影响 **新开** 的进程;当前 PowerShell 要关了重开才看得到。" -ForegroundColor Yellow
