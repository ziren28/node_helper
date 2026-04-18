#requires -Version 5.1
# ============================================================
#  node_helper V3.2 · Windows 一键管理脚本(PowerShell,菜单版)
#
#  功能:install / reset / lock-claude / status / configure
#        / uninstall / self-update
#  行为对齐 Linux 的 scripts/linux/node-helper.sh
#
#  仓库: https://github.com/ziren28/node_helper  (main 分支)
#
#  交互:
#    powershell -ExecutionPolicy Bypass -File node-helper.ps1       显示菜单
#
#  命令行:
#    .\node-helper.ps1 install [-Global] [-Cjs]
#    .\node-helper.ps1 reset [-NoClaude]
#    .\node-helper.ps1 lock-claude
#    .\node-helper.ps1 status
#    .\node-helper.ps1 configure
#    .\node-helper.ps1 uninstall [-Yes]
#    .\node-helper.ps1 self-update
#    .\node-helper.ps1 version
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$Subcommand = '',
    [switch]$Global,    # install/reset: 用全局 NODE_OPTIONS 模式
    [switch]$Esm,       # 用 --import (ESM)
    [switch]$Cjs,       # 用 --require (CJS)
    [switch]$NoClaude,  # reset 时跳过 claude 版本锁
    [switch]$Yes,       # uninstall 无交互
    [string]$Prefix,
    [string]$Bin
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol

# ============================================================
#  常量
# ============================================================
$script:VERSION            = '3.2.0'
$script:REPO_OWNER         = 'ziren28'
$script:REPO_NAME          = 'node_helper'
$script:REPO_BRANCH        = 'main'
$script:RAW_BASE           = "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"
$script:CLAUDE_CODE_VERSION = '2.1.112'
$script:TARBALL_URL        = "$RAW_BASE/vendor/claude-code-$CLAUDE_CODE_VERSION.tgz"
$script:SELF_URL           = "$RAW_BASE/node-helper.ps1"
$script:TASK_NAME          = 'NodeHelperClaudeLock'

$script:REMOTE_FILES = @(
    'intercept.cjs','intercept.mjs','package.json','.env.example',
    'prompts/minimal_strip.txt','prompts/strip_reminders.txt',
    'prompts/system.txt','prompts/system_patterns.txt'
)

if (-not $Prefix) { $Prefix = Join-Path $env:LOCALAPPDATA 'node-helper' }
if (-not $Bin)    { $Bin    = Join-Path $env:USERPROFILE 'bin' }
$script:PREFIX    = $Prefix
$script:BIN_DIR   = $Bin
$script:WRAPPER   = Join-Path $BIN_DIR 'claude.cmd'
$script:CACHE_DIR = Join-Path $env:LOCALAPPDATA 'node-helper-dl'

# ============================================================
#  输出工具
# ============================================================
function Write-OK    { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Bad   { param($m) Write-Host "  $m" -ForegroundColor Red }
function Write-Title { param($m) Write-Host $m   -ForegroundColor Cyan }
function Write-Dim   { param($m) Write-Host $m   -ForegroundColor DarkGray }
function Say-OK      { param($m) Write-Host "✓ $m" -ForegroundColor Green }
function Say-Warn    { param($m) Write-Host "⚠ $m" -ForegroundColor Yellow }
function Say-Bad     { param($m) Write-Host "✗ $m" -ForegroundColor Red }

function Confirm-Ask {
    param([string]$Prompt)
    if ($Yes) { return $true }
    $a = Read-Host "$Prompt [y/N]"
    return $a -match '^[yY]'
}

function Download-File {
    param([string]$Url, [string]$Out)
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Out -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-LocalClaudeVersion {
    # npm 输出可能被其它 NODE_OPTIONS hook 的 banner 污染,逐行过滤,只取看起来像路径的那行
    try {
        $raw = (& npm prefix -g 2>$null) -split "`r?`n"
        $npmPrefix = $raw | Where-Object { $_ -match '^[A-Za-z]:\\' } | Select-Object -Last 1
        if (-not $npmPrefix) { return '' }
        $npmPrefix = $npmPrefix.Trim()
        $pj = Join-Path $npmPrefix 'node_modules\@anthropic-ai\claude-code\package.json'
        if (-not (Test-Path $pj -ErrorAction SilentlyContinue)) { return '' }
        return (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version
    } catch { return '' }
}

function Get-RemoteClaudeHelperVersion {
    try {
        $pj = Invoke-WebRequest -UseBasicParsing -Uri "$RAW_BASE/package.json" -ErrorAction Stop
        return ($pj.Content | ConvertFrom-Json).version
    } catch { return '' }
}

# ============================================================
#  子命令实现
# ============================================================
function Invoke-Install {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '需要 Node.js ≥ 18' }
    $nmaj = [int](& node -p "process.versions.node.split('.')[0]")
    if ($nmaj -lt 18) { throw "Node 版本太低 ($nmaj),需要 ≥ 18" }

    $mode   = if ($Global) { 'global' } else { 'wrapper' }
    $loader = if ($Cjs)    { 'cjs' }    else { 'esm' }

    Write-Host ''
    Write-Title "━━━ 安装 ━━━"
    Write-Host "  模式:    $mode"
    Write-Host "  加载器:  $loader"
    Write-Host "  安装到:  $PREFIX"
    if ($mode -eq 'wrapper') { Write-Host "  wrapper: $WRAPPER" }
    Write-Host ''

    # 复制 / 下载依赖
    New-Item -ItemType Directory -Path $PREFIX -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $PREFIX 'prompts') -Force | Out-Null

    $scriptDir = if ($PSCommandPath) { Split-Path $PSCommandPath } else { $PWD }
    foreach ($f in $REMOTE_FILES) {
        $dst = Join-Path $PREFIX $f
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force -ErrorAction SilentlyContinue | Out-Null
        $localSrc = Join-Path $scriptDir $f
        if (Test-Path $localSrc) {
            Copy-Item $localSrc $dst -Force
            Say-OK "$f  (local)"
        } elseif (Download-File "$RAW_BASE/$f" $dst) {
            Say-OK "$f  (github)"
        } else {
            Say-Bad "$f 下载失败"; throw "依赖未齐备"
        }
    }
    if (-not (Test-Path (Join-Path $PREFIX '.env')) -and (Test-Path (Join-Path $PREFIX '.env.example'))) {
        Copy-Item (Join-Path $PREFIX '.env.example') (Join-Path $PREFIX '.env')
    }

    # 计算 NODE_OPTIONS 值
    $interceptMjs = (Join-Path $PREFIX 'intercept.mjs') -replace '\\','/'
    $interceptCjs = (Join-Path $PREFIX 'intercept.cjs')
    $flag = if ($loader -eq 'esm' -and (Test-Path (Join-Path $PREFIX 'intercept.mjs'))) {
        "--import=file:///$interceptMjs"
    } else {
        "--require=$interceptCjs"
    }

    if ($mode -eq 'wrapper') {
        New-Item -ItemType Directory -Path $BIN_DIR -Force | Out-Null
        # 生成 wrapper(注意 !NODE_OPTIONS! 要留给 cmd 的延迟展开)
        $cmdContent = @"
@echo off
REM node_helper V3.2 wrapper - 临时禁用: set CLAUDE_INTERCEPT=off ^& claude
setlocal EnableDelayedExpansion
if /I not "%CLAUDE_INTERCEPT%"=="off" (
  if defined NODE_OPTIONS (
    set "NODE_OPTIONS=$flag !NODE_OPTIONS!"
  ) else (
    set "NODE_OPTIONS=$flag"
  )
)
set "_SELF=%~f0"
set "_REAL="
for /f "delims=" %%i in ('where claude 2^>nul') do (
  if /I not "%%~fi"=="%_SELF%" if not defined _REAL set "_REAL=%%~fi"
)
if not defined _REAL ( echo [node_helper] PATH 上找不到真 claude 1^>^&2 & exit /b 127 )
call "%_REAL%" %*
"@
        [System.IO.File]::WriteAllText($WRAPPER, $cmdContent, [System.Text.Encoding]::ASCII)
        Say-OK "wrapper: $WRAPPER"

        # 检查 BIN_DIR 是否在 PATH(用户级)
        $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if (-not $userPath) { $userPath = '' }
        if (-not ($userPath -split ';' | Where-Object { $_ -eq $BIN_DIR })) {
            Write-Warn "$BIN_DIR 不在用户 PATH"
            if (Confirm-Ask "加到用户 PATH(写 HKCU\Environment)") {
                $newPath = if ($userPath) { "$BIN_DIR;$userPath" } else { $BIN_DIR }
                [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
                Say-OK '已加到 PATH 最前(重开终端生效)'
            }
        }
    }
    elseif ($mode -eq 'global') {
        $cur = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')
        $new = if ($cur) { "$flag $cur" } else { $flag }
        [Environment]::SetEnvironmentVariable('NODE_OPTIONS', $new, 'User')
        Say-OK "已写 HKCU\Environment\NODE_OPTIONS"
        Write-Host "    $new"
    }

    Write-Host ''
    Say-OK "安装完成  (v$VERSION)"
    Write-Host '  验证:  CLAUDE_INTERCEPT_DEBUG=1 claude --version'
    Write-Host '  看到 [ic v3] active 就是挂上了'
}

function Invoke-LockClaude {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw '需要 npm' }

    Write-Host ''
    Write-Title "━━━ 锁定 Claude Code 到 $CLAUDE_CODE_VERSION ━━━"
    Write-Host "(2.1.113+ 是 SEA 原生二进制,NODE_OPTIONS 失效,我们的 hook 对 SEA 无效)"
    Write-Host ''

    $cur = Get-LocalClaudeVersion
    Write-Host "  当前:  $(if($cur){$cur}else{'(未装)'})"
    Write-Host "  目标:  $CLAUDE_CODE_VERSION"
    Write-Host ''

    if ($cur -eq $CLAUDE_CODE_VERSION) {
        Say-OK '已是目标版本,跳过重装'
    } else {
        Write-Host '[1/2] 装 Claude Code'
        if ($cur) {
            & npm uninstall -g '@anthropic-ai/claude-code' 2>&1 | Select-Object -Last 3 | ForEach-Object { "    $_" }
        }
        New-Item -ItemType Directory -Path $CACHE_DIR -Force | Out-Null
        $tarball = Join-Path $CACHE_DIR "claude-code-$CLAUDE_CODE_VERSION.tgz"
        if ((Download-File $TARBALL_URL $tarball) -and (Test-Path $tarball) -and (Get-Item $tarball).Length -gt 100000) {
            Say-OK "从 GitHub vendor/ 拉 tarball ($([math]::Round((Get-Item $tarball).Length/1MB,1)) MB)"
            & npm install -g "$tarball" 2>&1 | Select-Object -Last 5 | ForEach-Object { "    $_" }
        } else {
            Say-Warn 'GitHub 拉不到 tarball,回退 npm registry'
            & npm install -g "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" 2>&1 | Select-Object -Last 5 | ForEach-Object { "    $_" }
        }
        $cur = Get-LocalClaudeVersion
        if ($cur -ne $CLAUDE_CODE_VERSION) { throw "装完后版本是 '$cur',预期 '$CLAUDE_CODE_VERSION'" }
        Say-OK "Claude Code $CLAUDE_CODE_VERSION 已装"
    }

    Write-Host ''
    Write-Host '[2/2] 装 Task Scheduler 防漂移任务'
    New-Item -ItemType Directory -Path $PREFIX -Force | Out-Null
    $taskScript = Join-Path $PREFIX 'claude-lock.cmd'
    $logFile    = Join-Path $env:LOCALAPPDATA 'node-helper-claude-lock.log'
    $npmPrefix  = (& npm prefix -g 2>$null)
    $pkgJson    = Join-Path $npmPrefix 'node_modules\@anthropic-ai\claude-code\package.json'

    $cmdBody = @"
@echo off
REM node_helper · Claude Code 版本锁 · 每天 Task Scheduler 触发
REM 目标: $CLAUDE_CODE_VERSION(最后一个 JS 版)
setlocal EnableDelayedExpansion
set "PKG=$pkgJson"
set "TARGET=$CLAUDE_CODE_VERSION"
set "LOG=$logFile"
set "CUR="
if exist "%PKG%" (
  for /f "tokens=2 delims=:" %%a in ('findstr /C:"\"version\"" "%PKG%"') do (
    set "CUR=%%~a"
    set "CUR=!CUR:"=!"
    set "CUR=!CUR:,=!"
    set "CUR=!CUR: =!"
    goto :gotver
  )
)
:gotver
if "!CUR!"=="!TARGET!" exit /b 0
echo [%date% %time%] drift: !CUR! -^> reinstalling !TARGET! >> "%LOG%"
call npm uninstall -g @anthropic-ai/claude-code >> "%LOG%" 2>&1
set "TARBALL=$CACHE_DIR\claude-code-!TARGET!.tgz"
if exist "!TARBALL!" (
  call npm install -g "!TARBALL!" >> "%LOG%" 2>&1
) else (
  call npm install -g @anthropic-ai/claude-code@!TARGET! >> "%LOG%" 2>&1
)
echo [%date% %time%] reinstall done >> "%LOG%"
"@
    [System.IO.File]::WriteAllText($taskScript, $cmdBody, [System.Text.Encoding]::ASCII)

    # 删老任务再建
    schtasks /Delete /TN $TASK_NAME /F 2>$null | Out-Null
    $taskCmd = "cmd /c `"$taskScript`""
    $createOut = schtasks /Create /TN $TASK_NAME /SC DAILY /ST 03:00 /TR $taskCmd /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say-OK "Scheduled Task 已装: $TASK_NAME"
        Write-Host "    每天 03:00 检查,偏离 $CLAUDE_CODE_VERSION 就自动 npm install -g 回滚"
        Write-Host "    日志: $logFile"
    } else {
        Say-Warn "schtasks 创建失败: $createOut"
    }

    Write-Host ''
    $which = (Get-Command claude -ErrorAction SilentlyContinue).Source
    Say-OK "完成。claude → $which  版本 $(Get-LocalClaudeVersion)"
}

function Invoke-Reset {
    Write-Host ''
    Write-Title '━━━ 强制重置(clean + remote pull + reinstall)━━━'
    Write-Host ''

    # 1. wrapper
    Write-Host '[1/5] 清 wrapper'
    $wrappers = @(
        $WRAPPER,
        (Join-Path $env:USERPROFILE 'bin\claude.cmd'),
        (Join-Path $env:USERPROFILE 'bin\claude')
    ) | Select-Object -Unique
    $killed = 0
    foreach ($w in $wrappers) {
        if ((Test-Path $w) -and (Select-String -Path $w -Pattern 'node_helper' -Quiet -ErrorAction SilentlyContinue)) {
            Remove-Item $w -Force
            Say-OK "已删 $w"; $killed++
        }
    }
    if ($killed -eq 0) { Write-Dim '    (无)' }

    # 2. 全局 NODE_OPTIONS 注入
    Write-Host '[2/5] 清 NODE_OPTIONS 中我们写过的 --require/--import'
    $cur = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')
    if ($cur) {
        # 只清我们写的这块,不动用户自己的其它 flag
        $cleaned = ($cur -replace '--(require|import)=[^\s]*(node-helper|intercept\.cjs|intercept\.mjs|node_helper)[^\s]*','').Trim()
        if ($cleaned -ne $cur) {
            if ($cleaned) {
                [Environment]::SetEnvironmentVariable('NODE_OPTIONS', $cleaned, 'User')
                Say-OK "已从 NODE_OPTIONS 里剥离我们的片段"
            } else {
                [Environment]::SetEnvironmentVariable('NODE_OPTIONS', '', 'User')
                Say-OK '已清 NODE_OPTIONS(整个)'
            }
        } else { Write-Dim '    (无需改)' }
    } else { Write-Dim '    (空)' }

    # 3. PREFIX(保留 .env)
    Write-Host "[3/5] 清 $PREFIX(保留 .env)"
    if (Test-Path $PREFIX) {
        $envBak = $null
        $envPath = Join-Path $PREFIX '.env'
        if (Test-Path $envPath) { $envBak = Get-Content $envPath -Raw -Encoding UTF8 }
        Remove-Item $PREFIX -Recurse -Force
        Say-OK '已删'
        if ($envBak) {
            New-Item -ItemType Directory -Path $PREFIX -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $PREFIX '.env'), $envBak, [System.Text.UTF8Encoding]::new($false))
            Say-OK '已还原旧 .env'
        }
    } else { Write-Dim '    (不存在)' }

    # 4. 下载缓存
    Write-Host "[4/5] 清下载缓存 $CACHE_DIR"
    if (Test-Path $CACHE_DIR) { Remove-Item $CACHE_DIR -Recurse -Force; Say-OK '已清' }
    else { Write-Dim '    (不存在)' }

    # 5. 从 GitHub 拉 + 装
    Write-Host '[5/5] 从 GitHub 拉 + 装 wrapper + 激活'
    Invoke-Install

    # Claude 版本锁
    if (-not $NoClaude) {
        Invoke-LockClaude
    } else {
        Write-Dim '  (--NoClaude: 跳过 Claude 版本锁)'
    }

    Write-Host ''
    Write-Title '━━━ 重置完成 ━━━'
    Write-Host '  新开一个终端(让 PATH 生效),然后:'
    Write-Host '    CLAUDE_INTERCEPT_DEBUG=1 claude --version'
}

function Invoke-Status {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 让单个检查出错时不中断后续项
    Write-Host ''
    Write-Title '━━━ 状态 ━━━'

    Write-Host '[1] 安装目录'
    if (Test-Path $PREFIX) {
        Say-OK $PREFIX
        foreach ($f in 'intercept.cjs','intercept.mjs','package.json','.env') {
            if (Test-Path (Join-Path $PREFIX $f)) { Write-Host "      ✓ $f" -ForegroundColor Green }
            else { Write-Host "      ✗ $f" -ForegroundColor Red }
        }
    } else { Say-Bad "未装: $PREFIX" }

    Write-Host ''
    Write-Host '[2] wrapper'
    if ((Test-Path $WRAPPER) -and (Select-String -Path $WRAPPER -Pattern 'node_helper' -Quiet -ErrorAction SilentlyContinue)) {
        Say-OK $WRAPPER
    } else { Write-Dim '    (未装)' }

    Write-Host ''
    Write-Host '[3] 全局 NODE_OPTIONS (HKCU\Environment)'
    $no = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')
    if ($no) { Say-OK $no } else { Write-Dim '    (空)' }

    Write-Host ''
    Write-Host '[4] which claude'
    $w = Get-Command claude -ErrorAction SilentlyContinue
    if ($w) {
        Write-Host "    $($w.Source)"
        if ($w.Source -eq $WRAPPER) { Say-OK '是我们的 wrapper' } else { Say-Warn '不是 wrapper(PATH 顺序?)' }
    } else { Say-Bad '找不到 claude' }

    Write-Host ''
    Write-Host '[5] Claude Code 版本'
    $ccv = Get-LocalClaudeVersion
    Write-Host "    本地: $(if($ccv){$ccv}else{'(未装)'})"
    Write-Host "    目标: $CLAUDE_CODE_VERSION"
    if ($ccv -eq $CLAUDE_CODE_VERSION) { Say-OK '已锁定' }
    else { Say-Warn '版本漂移 / 未锁定(建议 lock-claude)' }

    Write-Host ''
    Write-Host '[6] 防漂移 Task Scheduler'
    schtasks /Query /TN $TASK_NAME /FO LIST 2>$null | Out-Null
    $code = $LASTEXITCODE; $global:LASTEXITCODE = 0
    if ($code -eq 0) {
        Say-OK "已装: $TASK_NAME"
    } else { Write-Dim '    (未装)' }

    Write-Host ''
    Write-Host '[7] 版本对比'
    $local  = '3.2.0'
    $remote = Get-RemoteClaudeHelperVersion
    Write-Host "    本脚本: $local"
    Write-Host "    远程:   $(if($remote){$remote}else{'(拉不到)'})"
    Write-Host ''
    $ErrorActionPreference = $old
}

function Invoke-Configure {
    $envf = Join-Path $PREFIX '.env'
    if (-not (Test-Path $envf)) {
        $exf = Join-Path $PREFIX '.env.example'
        if (Test-Path $exf) { Copy-Item $exf $envf; Say-OK "已从模板生成 $envf" }
        else { throw "$envf 不存在,先 install" }
    }
    $editor = if ($env:EDITOR) { $env:EDITOR } else { 'notepad' }
    Say-OK "打开: $editor $envf"
    & $editor $envf
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Title '━━━ 卸载 ━━━'

    if ((Test-Path $WRAPPER) -and (Select-String -Path $WRAPPER -Pattern 'node_helper' -Quiet -ErrorAction SilentlyContinue)) {
        if (Confirm-Ask "删 wrapper $WRAPPER") { Remove-Item $WRAPPER -Force; Say-OK '已删' }
    }

    $no = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'User')
    if ($no -match 'node[-_]helper|intercept\.(cjs|mjs)') {
        if (Confirm-Ask "清用户 NODE_OPTIONS(当前: $no)") {
            [Environment]::SetEnvironmentVariable('NODE_OPTIONS', '', 'User')
            Say-OK '已清'
        }
    }

    if (Test-Path $PREFIX) {
        if (Test-Path (Join-Path $PREFIX '.env')) {
            Say-Warn "$PREFIX\.env 可能含你的配置 / token"
        }
        if (Confirm-Ask "删 $PREFIX") { Remove-Item $PREFIX -Recurse -Force; Say-OK '已删' }
    }
    if (Test-Path $CACHE_DIR) {
        if (Confirm-Ask "清下载缓存 $CACHE_DIR") { Remove-Item $CACHE_DIR -Recurse -Force; Say-OK '已清' }
    }

    schtasks /Query /TN $TASK_NAME 2>$null | Out-Null
    $code = $LASTEXITCODE; $global:LASTEXITCODE = 0
    if ($code -eq 0) {
        if (Confirm-Ask "删 Scheduled Task '$TASK_NAME'") {
            schtasks /Delete /TN $TASK_NAME /F 2>&1 | Out-Null
            $global:LASTEXITCODE = 0
            Say-OK '已删'
        }
    }

    Write-Host ''
    Say-OK '卸载完成'
    $w = (Get-Command claude -ErrorAction SilentlyContinue).Source
    Write-Host "  which claude → $(if($w){$w}else{'(PATH 无 claude)'})"
}

function Invoke-SelfUpdate {
    Write-Host ''
    Write-Title '━━━ 自更新 ━━━'
    $dl = Join-Path $env:TEMP 'node-helper-new.ps1'
    if (-not (Download-File $SELF_URL $dl)) { throw "下载 $SELF_URL 失败" }
    if (-not $PSCommandPath) { throw '无法确定本脚本路径(可能被 pipe 运行),请手动替换' }

    $curHash = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash
    $newHash = (Get-FileHash $dl -Algorithm SHA256).Hash
    if ($curHash -eq $newHash) {
        Say-OK '已是最新';
        Remove-Item $dl -Force
        return
    }
    Say-Warn '发现新版'
    if (Confirm-Ask "用新版替换 $PSCommandPath(原文件备份 .bak)") {
        $bak = "$PSCommandPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $PSCommandPath $bak
        Copy-Item $dl $PSCommandPath -Force
        Remove-Item $dl -Force
        Say-OK "已更新(备份 $bak)"
    } else { Remove-Item $dl -Force }
}

# ============================================================
#  交互菜单
# ============================================================
function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Title '╔══════════════════════════════════════════════════════╗'
        Write-Title "║   node_helper V$VERSION · Claude Code 拦截与改写(Win)     ║"
        Write-Title "║   github.com/$REPO_OWNER/$REPO_NAME                 ║"
        Write-Title '╚══════════════════════════════════════════════════════╝'
        Write-Host ''
        $ccv = Get-LocalClaudeVersion
        if (Test-Path $PREFIX) {
            Write-Host "  安装状态:  " -NoNewline; Write-Host "✓ 已安装" -ForegroundColor Green -NoNewline
            Write-Host "  ($PREFIX)"
        } else { Write-Dim '  安装状态:  未安装' }
        $ccvTag = if (-not $ccv) { '未装' }
                  elseif ($ccv -eq $CLAUDE_CODE_VERSION) { "$ccv (已锁)" }
                  else { "$ccv (未锁,建议 8)" }
        Write-Host "  Claude CC: $ccvTag"
        Write-Host ''
        Write-Dim   '────────────────────────────────────────────────────────'
        Write-Host '   1) 安装 / 重装'
        Write-Host '   2) 查看详细状态'
        Write-Host '   3) 编辑 .env 配置'
        Write-Host '   4) 卸载'
        Write-Host ''
        Write-Host '   7) ' -NoNewline; Write-Host '强制重置' -ForegroundColor Cyan -NoNewline
        Write-Host "         (清 + 拉 + 装 + 锁 Claude $CLAUDE_CODE_VERSION)"
        Write-Host "   8) 只锁 Claude Code    (装/回滚 $CLAUDE_CODE_VERSION + Task Scheduler)"
        Write-Host '   9) 自更新此脚本        (从 GitHub 拉最新)'
        Write-Host ''
        Write-Host '   0) 退出'
        Write-Dim   '────────────────────────────────────────────────────────'
        $c = Read-Host '  请选择 [0-9]'
        Write-Host ''
        try {
            switch ($c) {
                '1' { Invoke-Install }
                '2' { Invoke-Status }
                '3' { Invoke-Configure }
                '4' { Invoke-Uninstall }
                '7' { Invoke-Reset }
                '8' { Invoke-LockClaude }
                '9' { Invoke-SelfUpdate }
                '0' { Write-Host '再见'; return }
                'q' { return }
                'Q' { return }
                default { Say-Bad '无效选择'; Start-Sleep -Milliseconds 700 }
            }
        } catch {
            Say-Bad $_.Exception.Message
        }
        if ($c -match '^[0qQ]$') { return }
        Write-Host ''
        Read-Host '  按回车回主菜单' | Out-Null
    }
}

# ============================================================
#  分发
# ============================================================
try {
    switch ($Subcommand) {
        ''              { Show-Menu }
        'install'       { Invoke-Install }
        'reset'         { Invoke-Reset }
        'fresh'         { Invoke-Reset }
        'lock-claude'   { Invoke-LockClaude }
        'lock'          { Invoke-LockClaude }
        'status'        { Invoke-Status }
        'st'            { Invoke-Status }
        'configure'     { Invoke-Configure }
        'config'        { Invoke-Configure }
        'uninstall'     { Invoke-Uninstall }
        'remove'        { Invoke-Uninstall }
        'self-update'   { Invoke-SelfUpdate }
        'menu'          { Show-Menu }
        'version'       { Write-Host "node_helper v$VERSION"; exit 0 }
        'help'          {
            Write-Host ''
            Write-Host 'node_helper V3.2 · Windows 一键管理脚本'
            Write-Host ''
            Write-Host '用法:'
            Write-Host '  .\node-helper.ps1 [command] [options]'
            Write-Host ''
            Write-Host 'command:'
            Write-Host '  (无)             显示菜单'
            Write-Host '  install          安装(wrapper 模式 + ESM)'
            Write-Host '  reset            清 + 重装 + 锁 claude'
            Write-Host '  lock-claude      只装/回滚 Claude Code 到 2.1.112 + Task'
            Write-Host '  status           状态(7 项)'
            Write-Host '  configure        打开 .env 编辑'
            Write-Host '  uninstall        卸载'
            Write-Host '  self-update      从 GitHub 拉最新脚本替换自己'
            Write-Host '  version          打印版本号'
            Write-Host ''
            Write-Host 'options:'
            Write-Host '  -Global          install/reset: 用全局 NODE_OPTIONS 模式'
            Write-Host '  -Esm / -Cjs      加载器选择(默认 Esm)'
            Write-Host '  -NoClaude        reset: 不动 Claude Code 版本'
            Write-Host '  -Yes             uninstall: 无交互'
            Write-Host '  -Prefix DIR      安装目录(默认 %LOCALAPPDATA%\node-helper)'
            Write-Host '  -Bin DIR         wrapper 目录(默认 %USERPROFILE%\bin)'
            exit 0
        }
        default         { Say-Bad "未知子命令: $Subcommand"; exit 2 }
    }
} catch {
    Say-Bad $_.Exception.Message
    exit 1
}
