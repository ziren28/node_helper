# install-global.ps1 — 把 V3 intercept.cjs 注册成用户级全局 NODE_OPTIONS
#
# 配合 intercept.cjs 里的"入口门禁",只在 Claude 进程里真正激活,
# 其它 Node 进程(npm / VS Code / dev server / Electron 等)加载后立即 return,
# 不装 hook、不改请求,零副作用。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File install-global.ps1
#
# 卸载:
#   powershell -ExecutionPolicy Bypass -File uninstall-global.ps1

param([switch]$Force)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$InterceptPath = Join-Path $Root 'intercept.cjs'
$Flag = "--require=$InterceptPath"

if (-not (Test-Path $InterceptPath)) {
    Write-Host "[!] intercept.cjs 不存在: $InterceptPath" -ForegroundColor Red
    exit 1
}

# 读现有的 NODE_OPTIONS(用户级)
$existing = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " node_helper V3 · 全局 NODE_OPTIONS 安装" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "intercept.cjs 路径: $InterceptPath"
Write-Host ""
Write-Host "现有 NODE_OPTIONS (User):" -ForegroundColor Yellow
Write-Host "  $existing"
Write-Host ""

# 检查是否已包含
if ($existing -and $existing.Contains($Flag)) {
    Write-Host "[=] 已经安装,NODE_OPTIONS 里已含 intercept.cjs 的 --require" -ForegroundColor Green
    if (-not $Force) {
        Write-Host "    加 -Force 可强制重装" -ForegroundColor Gray
        exit 0
    }
}

# 追加(保留用户已有的 NODE_OPTIONS 其它部分)
$new = if ($existing -and -not $existing.Contains($Flag)) {
    "$Flag $existing"
} else {
    $Flag
}

# setx 写入用户级环境变量(持久化,新开终端/登录都生效)
& setx NODE_OPTIONS "$new" | Out-Null

Write-Host "[✓] 写入 NODE_OPTIONS (User):" -ForegroundColor Green
Write-Host "    $new"
Write-Host ""
Write-Host "注意:" -ForegroundColor Yellow
Write-Host "  1. setx 只影响 **新开** 的进程;当前 PowerShell 没效。"
Write-Host "  2. 任何 Node 进程启动都会加载 intercept.cjs,但它会先检查'我是不是 Claude',"
Write-Host "     不是就立刻 return,不 hook、不改,零副作用。"
Write-Host "  3. 调试:设 CLAUDE_INTERCEPT_DEBUG=1 能看到'跳过哪些 Node 进程'。"
Write-Host "  4. 想临时关:任何 shell 里 set/export CLAUDE_INTERCEPT_NEVER=1"
Write-Host ""
Write-Host "验证(新开终端后):" -ForegroundColor Cyan
Write-Host "  echo `$env:NODE_OPTIONS"
Write-Host "  claude --version     # 应看到 [ic v3] active 的 banner"
Write-Host ""
Write-Host "卸载:" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File $Root\uninstall-global.ps1"
