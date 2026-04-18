# node_helper · Claude Code 拦截 + 改写工具

通过 Node 的 `--require` / `--import` 钩子拦截 [Claude Code](https://github.com/anthropics/claude-code) CLI 发往 `*.anthropic.com` 的所有 HTTP/HTTPS 流量,按 `.env` 里的规则改写请求或响应:剥除 `<system-reminder>`、替换 `system` 提示词、改 token / `anthropic-beta` / `metadata` / `max_tokens` / `thinking.budget_tokens`、记录所有请求到 JSONL 日志。

- **零侵入**:不改 Claude Code 源码,通过 NODE_OPTIONS 预加载介入
- **门禁过滤**:`intercept.cjs` 内部 gate 只在 Claude 进程激活,不污染其它 Node 程序
- **热更新**:改 `.env` / `prompts/` 即生效,不需要重启
- **双平台**:Linux(`node-helper.sh`)+ Windows(`node-helper.ps1`)
- **JS / SEA 版本兼容性**:Claude Code 2.1.113+ 改成了 SEA 原生二进制,`NODE_OPTIONS` 失效;本工具自动锁定到最后一个 JS 版 **2.1.112**,并加每日 cron / Task Scheduler 防漂移

---

## 目录

- [快速开始](#快速开始)
- [架构](#架构)
- [配置](#配置)
- [菜单 vs 命令行](#菜单-vs-命令行)
- [规则文件](#规则文件)
- [Claude Code 版本锁](#claude-code-版本锁)
- [文件结构](#文件结构)
- [常见问题](#常见问题)
- [卸载](#卸载)

---

## 快速开始

### Linux (一行装到位)

```bash
curl -fsSL https://raw.githubusercontent.com/ziren28/node_helper/main/node-helper.sh -o /tmp/nh.sh
bash /tmp/nh.sh reset
```

`reset` 默认会:
1. 清理任何旧版痕迹
2. 从 GitHub 拉最新依赖到 `~/.local/share/node-helper`
3. 装 wrapper 到 `/usr/local/bin/claude`(root)或 `~/.local/bin/claude`(非 root)
4. 把 Claude Code 锁到 `2.1.112`(最后一个支持 hook 的版本)
5. 加每日 cron 防漂移

完成后:

```bash
hash -r                                                # 清 bash 命令缓存
CLAUDE_INTERCEPT_DEBUG=1 claude --version              # 看到 [ic v3] active = 挂上了
```

### Windows (PowerShell 菜单版)

```powershell
iwr https://raw.githubusercontent.com/ziren28/node_helper/main/node-helper.ps1 -O nh.ps1
powershell -ExecutionPolicy Bypass -File .\nh.ps1
# 进入交互菜单,选 7) 强制重置
```

或一键无 UI 模式:

```powershell
powershell -ExecutionPolicy Bypass -File .\nh.ps1 reset
```

### 老式 Windows(全局 NODE_OPTIONS,不锁版本)

```powershell
# clone 仓库后
.\install-global.cmd
# 或
powershell -ExecutionPolicy Bypass -File install-global.ps1
```

---

## 架构

```
                        你输入  claude "hi"
                              │
                              ▼
                   ┌─────────────────────────┐
                   │  PATH 解析 → wrapper    │   /usr/local/bin/claude
                   │  (set NODE_OPTIONS)     │   或 %USERPROFILE%\bin\claude.cmd
                   └────────────┬────────────┘
                                │
                                ▼
                   ┌─────────────────────────┐
                   │  exec 真正的 claude     │   npm 装的 cli.js (2.1.112)
                   │  (Node 启动)            │
                   └────────────┬────────────┘
                                │ 读 NODE_OPTIONS
                                ▼
                   ┌─────────────────────────┐
                   │  intercept.mjs / .cjs   │   gate 检查 → 是 Claude 进程
                   │  monkey-patch 网络层    │   → hook https.request + fetch
                   └────────────┬────────────┘
                                │
                                ▼
                   ┌─────────────────────────┐
                   │  改写规则               │   按 .env 配置:
                   │  · 剥 system-reminder   │   STRIP_REMINDERS_MODE=matched
                   │  · 替换 system 提示词   │   SYSTEM_REPLACE_FILE=...
                   │  · 改 header / metadata │   HEADER_AUTH_REPLACE=...
                   │  · 改 max_tokens / 思考 │   MAX_TOKENS_CAP=...
                   └────────────┬────────────┘
                                │
                                ▼
                          api.anthropic.com
                                │
                  ┌─────────────┴──────────────┐
                  │                            │
              真实响应                   日志旁路 (JSONL)
                  │                            │
                  ▼                            ▼
              Claude UI                   /tmp/node-helper-intercept.jsonl
                                          (或可选 viewer:8787)
```

### 入口门禁

`intercept.cjs` 顶部有"门禁"逻辑(`shouldActivate()`),只在以下情况激活:

| 信号 | 含义 |
|---|---|
| `CLAUDECODE` env 存在 | Claude Code 自身设的标记 |
| `CLAUDE_CODE_ENTRYPOINT` env 存在 | 同上 |
| `CLAUDE_AGENT_SDK_VERSION` env 存在 | Claude Agent SDK |
| `CLAUDE_CODE_OAUTH_TOKEN` env 存在 | OAuth token 在场 |
| `CLAUDE_CODE_EXECPATH` env 存在 | Desktop 注入 |
| `process.argv[1]` 含 "claude" | argv 兜底 |
| `require.main.filename` 含 "claude-code" / "@anthropic-ai" | 主入口兜底 |
| `CLAUDE_INTERCEPT_FORCE=1` | 调试强制开 |

任一命中 → 装 hook;全不命中 → `module.exports = {}` 直接 return,**0 副作用**。所以即使设了全局 `NODE_OPTIONS=--require=intercept.cjs`,VS Code / npm / dev server 等无关 Node 进程也不会被影响。

---

## 配置

主配置文件:`$PREFIX/.env`(Linux 默认 `~/.local/share/node-helper/.env`,Windows 默认 `%LOCALAPPDATA%\node-helper\.env`)

第一次安装时会自动从 `.env.example` 复制。手动编辑:

```bash
bash node-helper.sh configure         # 用 $EDITOR 打开
# 或直接编辑
vim ~/.local/share/node-helper/.env
```

### 关键字段速查

```ini
# ─── 总开关 ───
CLAUDE_INTERCEPT=on                # off = 整个 hook 旁路

# ─── 拦截目标 ───
TARGET_HOST_SUFFIX=anthropic.com   # hostname 以此结尾的请求才管

# ─── 日志 ───
LOG_MODE=file                      # off | stderr | file
LOG_FILE=/tmp/node-helper-intercept.jsonl
LOG_MASK_AUTH=true                 # JSONL 里 authorization / cookie 自动掩码
VIEWER_URL=http://127.0.0.1:8787/log    # 可选 viewer 旁路推送

# ─── header 改写 ───
HEADER_AUTH_REPLACE=               # 'Bearer sk-ant-api03-xxx' 启用替换
HEADER_BETA_REPLACE=               # 整替换 anthropic-beta(逗号分隔)
HEADER_BETA_DROP=                  # 从原列表删除指定 flag

# ─── system-reminder 清理 ───
STRIP_REMINDERS_MODE=matched       # off | matched | all
STRIP_REMINDERS_MATCHES_FILE=./prompts/strip_reminders.txt

# ─── body JSON 层改写 ───
MAX_TOKENS_CAP=                    # 整数,>cap 才砍(保底)
MAX_TOKENS_FORCE=                  # 整数,强制设置(优先于 cap)
BUDGET_CAP=                        # thinking.budget_tokens 上限
BUDGET_FORCE=                      # 强制
DISABLE_THINKING=false             # true 删整个 thinking 字段

# ─── metadata(追踪)改写 ───
FAKE_DEVICE_ID=                    # 改 user_id 的 device_id
FAKE_ACCOUNT_UUID=                 # 改 account_uuid
FAKE_SESSION_ID=                   # ⚠ 改这个会让 prompt 缓存失效
STRIP_METADATA=false               # true 整个删 metadata

# ─── system[2] 主指令块改写 ───
SYSTEM_REPLACE_FILE=./prompts/system.txt        # 替换 # System 那段
SYSTEM_FULL_REPLACE_FILE=                       # 整个 system[2] 替换
SYSTEM_PREFIX_FILE=                             # 在 system[2] 最前加
SYSTEM_SUFFIX_FILE=                             # 在 system[2] 末尾加
```

完整说明见 [.env.example](.env.example)

---

## 菜单 vs 命令行

两种用法等价:

| 操作 | 菜单(无参) | 命令行 |
|---|---|---|
| 装/重装 | 选 1 | `node-helper.sh install` |
| 查状态 | 选 2/3 | `node-helper.sh status` |
| 编辑 .env | 选 3/4 | `node-helper.sh configure` |
| 卸载 | 选 4/5 | `node-helper.sh uninstall [-y]` |
| **强制重置** | 选 7 | `node-helper.sh reset` |
| 锁 Claude 版本 | 选 8 | `node-helper.sh lock-claude` |
| 自更新脚本 | 选 9/6 | `node-helper.sh self-update` |

PowerShell 等价:

```powershell
.\node-helper.ps1                      # 菜单
.\node-helper.ps1 install
.\node-helper.ps1 reset
.\node-helper.ps1 lock-claude
.\node-helper.ps1 status
.\node-helper.ps1 configure
.\node-helper.ps1 uninstall -Yes
.\node-helper.ps1 self-update
```

### 安装模式

| 模式 | Linux 实现 | Windows 实现 | 影响范围 |
|---|---|---|---|
| **wrapper**(默认,推荐) | `/usr/local/bin/claude` shell wrapper | `%USERPROFILE%\bin\claude.cmd` | **只**在跑 `claude` 时生效 |
| **global** (`--global` / `-Global`) | 写 `~/.profile` 注入 NODE_OPTIONS | 写 `HKCU\Environment\NODE_OPTIONS` | 影响所有 Node 进程,靠 gate 过滤 |

### 加载器选择

| 加载器 | 默认 | 说明 |
|---|---|---|
| **ESM**(默认) | `--import=file:///.../intercept.mjs` | 现代 Node 标准,Node 18+ |
| **CJS** (`--cjs`) | `--require=.../intercept.cjs` | 老路径,兼容到 Node 14 |

两条路径**同时挂**也安全(intercept.cjs 顶部有双加载 guard)。

---

## 规则文件

`prompts/` 目录下都是纯文本,引用方式见 `.env`:

| 文件 | 引用 | 作用 |
|---|---|---|
| `prompts/strip_reminders.txt` | `STRIP_REMINDERS_MATCHES_FILE` | 一行一条匹配规则,前缀 `re:` 表示正则;命中的 `<system-reminder>...</system-reminder>` 整块剥掉 |
| `prompts/system.txt` | `SYSTEM_REPLACE_FILE` | 替换 system[2] 里 `# System` 段的内容 |
| `prompts/system_patterns.txt` | (可选) | 用于扩展 system 替换规则 |
| `prompts/minimal_strip.txt` | 替代 strip_reminders | 极简版,只剥几条最污染的 |

### strip_reminders 例子

```
# 一行一条;# 是注释。前缀 re: 表示正则
userEmail
currentDate
re:^.*As you answer the user's questions.*$
```

匹配的 `<system-reminder>` 块整体被删,不影响其它 reminder。

### system 替换例子

```
# system.txt 替换原 # System 段(不动 # Doing tasks / # Tone 等其它段)
# System
 - 用中文回答
 - 直接给结论,不解释过程
```

工具会找到 `# System` 标题段,替换内容到下一个 `# X` 标题前。

---

## Claude Code 版本锁

### 为什么锁

Claude Code 升级历史:

| 版本范围 | 包形态 | hook 是否生效 |
|---|---|---|
| `2.1.90` ~ `2.1.112` | **JS**(`bin/cli.js`,~47 MB) | ✅ 生效 |
| `2.1.113` 起 | **SEA 原生二进制**(`bin/claude.exe`,~236 MB) | ❌ NODE_OPTIONS 被锁死 |

`2.1.113` 是断点。`reset` 和 `lock-claude` 都会:
1. 卸载当前版本
2. 装 `2.1.112`(优先用 `vendor/claude-code-2.1.112.tgz` 离线副本,失败回退 npm registry)
3. 加每日定时任务,如果版本被升上去就自动回滚

### 定时任务详情

| 平台 | 位置 | 时间 |
|---|---|---|
| Linux (root) | `/etc/cron.daily/node-helper-claude-lock` | cron.daily 默认时段 |
| Linux (用户) | 用户 crontab | 每天 03:00 |
| Windows | Task Scheduler `NodeHelperClaudeLock` | 每天 03:00 |

任务脚本:读 `<npm-prefix>/node_modules/@anthropic-ai/claude-code/package.json` 的 version,如果 ≠ `2.1.112` 就 `npm install -g` 回滚。日志:
- Linux:`/var/log/node-helper-claude-lock.log`
- Windows:`%LOCALAPPDATA%\node-helper-claude-lock.log`

### 兜底:Anthropic 下架了 npm 上的 2.1.112

仓库内 `vendor/claude-code-2.1.112.tgz`(18 MB,npm 官方 tarball 副本)始终可用,作为永久离线安装源。`lock-claude` 第一次执行会把它缓存到 `~/.cache/node-helper-dl/`,即使 npm registry 下架,本机也能自愈。

---

## 文件结构

```
ziren28/node_helper                              GitHub 仓库
├── README.md                  本文件
├── package.json               { "type":"module", "version":"3.2.0", ... }
│
├── intercept.cjs              ★ 核心:806 行,所有 hook 和改写都在这里
├── intercept.mjs              ESM 入口,createRequire 委托给 .cjs
│
├── .env                       默认配置(可改)
├── .env.example               配置模板和说明
│
├── prompts/                   规则文件
│   ├── strip_reminders.txt    要剥掉的 system-reminder 模式
│   ├── minimal_strip.txt      极简版
│   ├── system.txt             system[2] # System 段替换
│   └── system_patterns.txt    扩展模式
│
├── vendor/
│   └── claude-code-2.1.112.tgz   ← 锁版本副本,18 MB
│
├── node-helper.sh             ★ Linux 一键管理(8 子命令 + 菜单)
├── node-helper.ps1            ★ Windows 一键管理(7 子命令 + 菜单)
│
├── install-global.cmd         (旧版)Windows 全局 NODE_OPTIONS 安装
├── install-global.ps1         (旧版)PowerShell 版本
├── uninstall-global.cmd       (旧版)对应卸载
└── uninstall-global.ps1       (旧版)
```

### 安装后(本机)文件分布

| Linux | 路径 |
|---|---|
| 主目录 | `~/.local/share/node-helper/` |
| wrapper | `/usr/local/bin/claude`(root) 或 `~/.local/bin/claude`(用户) |
| profile 注入(global 模式) | `~/.profile` 内 `# >>> node_helper V3.2 >>>` 块 |
| 下载缓存 | `~/.cache/node-helper-dl/` |
| 拦截日志 | `/tmp/node-helper-intercept.jsonl` |
| Claude 版本锁脚本 | `/etc/cron.daily/node-helper-claude-lock` |
| Claude 版本锁日志 | `/var/log/node-helper-claude-lock.log` |

| Windows | 路径 |
|---|---|
| 主目录 | `%LOCALAPPDATA%\node-helper\` |
| wrapper | `%USERPROFILE%\bin\claude.cmd` |
| 全局 NODE_OPTIONS(global 模式) | `HKCU\Environment\NODE_OPTIONS` |
| 下载缓存 | `%LOCALAPPDATA%\node-helper-dl\` |
| 拦截日志 | `%TEMP%\node-helper-intercept.jsonl` |
| Claude 版本锁脚本 | `%LOCALAPPDATA%\node-helper\claude-lock.cmd` |
| Task Scheduler | `NodeHelperClaudeLock` |

---

## 常见问题

### Q: 装完 `claude --version` 没看到 `[ic v3] active`

A: 三种原因之一,顺序自查:

1. **PATH 顺序**:你的 wrapper 没排在系统 claude 之前
   ```bash
   which -a claude              # 看顺序,我们的 wrapper 该是第 1 个
   echo "$PATH"                 # ~/.local/bin 或 /usr/local/bin 该在前
   hash -r                      # 清 bash 命令缓存
   ```

2. **bash 命令缓存**:bash 把第一次解析到的路径缓存了
   ```bash
   hash -r
   # 或开新终端
   ```

3. **Claude Code 是 SEA 版**(2.1.113+):NODE_OPTIONS 失效。运行
   ```bash
   bash node-helper.sh lock-claude
   ```
   降级到 2.1.112。

### Q: `lock-claude` 报"下载失败"

A: 可能是网络问题或仓库 raw 限速。检查:
```bash
curl -I https://raw.githubusercontent.com/ziren28/node_helper/main/vendor/claude-code-2.1.112.tgz
```
HTTP 200 就 OK。失败的话,脚本会自动回退到 npm registry。

### Q: 我改了 .env / prompts/ 没生效

A: intercept.cjs 在每条请求时检查文件 mtime,自动 reload。如果不生效:
```bash
# 看 intercept 的 banner 是否提到新文件
CLAUDE_INTERCEPT_DEBUG=1 claude --version
# 看日志里 LOG_FILE 字段
tail -f /tmp/node-helper-intercept.jsonl
```

### Q: 想临时关掉拦截

A: 设环境变量 `CLAUDE_INTERCEPT=off`:
```bash
CLAUDE_INTERCEPT=off claude   # 一次性
```
或永久关:
```bash
echo 'export CLAUDE_INTERCEPT=off' >> ~/.bashrc
```

### Q: Windows 上 `which claude` 还是指 npm

A: `%USERPROFILE%\bin` 没在 PATH 里,或不在最前。装 wrapper 时脚本会问"加到 PATH 吗",选 y。手动加:
```powershell
[Environment]::SetEnvironmentVariable('PATH', "$env:USERPROFILE\bin;$([Environment]::GetEnvironmentVariable('PATH','User'))", 'User')
# 重开 PowerShell
```

### Q: 想看完整 HTTP 流量(请求体 + 响应体)

A: 设 `LOG_MODE=file` + `LOG_FILE=...`,所有请求会追加到 JSONL,每行一个请求,含完整 headers / body / response。

### Q: 怎么验证锁在 2.1.112 没动

A:
```bash
# Linux
bash node-helper.sh status                       # 看 [5] / [6] 项
sudo /etc/cron.daily/node-helper-claude-lock     # 干跑一次,无输出即未漂移
cat /var/log/node-helper-claude-lock.log         # 历史漂移记录
```
```powershell
# Windows
.\node-helper.ps1 status                         # 看 [5] / [6] 项
schtasks /Run /TN NodeHelperClaudeLock           # 立即触发一次
Get-Content "$env:LOCALAPPDATA\node-helper-claude-lock.log" -Tail 10
```

---

## 卸载

```bash
# Linux
bash node-helper.sh uninstall            # 交互确认每一步
bash node-helper.sh uninstall -y         # 无人值守

# Windows
.\node-helper.ps1 uninstall
.\node-helper.ps1 uninstall -Yes
```

会清理:
- wrapper(`/usr/local/bin/claude` 或 `%USERPROFILE%\bin\claude.cmd`)
- `~/.profile` 注入块 / `HKCU\Environment\NODE_OPTIONS`
- `$PREFIX` 整个目录(`.env` 会询问)
- 下载缓存
- cron / Task Scheduler 任务

不会动:Claude Code 本身、其它 npm 包、PATH 注册顺序。

---

## 开发 / 贡献

```bash
git clone https://github.com/ziren28/node_helper.git
cd node_helper

# 改完任何文件,本地装一次试
bash node-helper.sh install --bin /tmp/test-bin --prefix /tmp/test-prefix

# 验证
NODE_OPTIONS="--import=file:///tmp/test-prefix/intercept.mjs" \
  CLAUDE_INTERCEPT_DEBUG=1 CLAUDE_INTERCEPT_FORCE=1 \
  node -e "console.log('hooks:', !!globalThis.__NODE_HELPER_V3_LOADED__)"

# 清理
rm -rf /tmp/test-prefix /tmp/test-bin/claude
```

PR 欢迎,尤其是:
- 更多 reminder 匹配规则(贡献到 `prompts/strip_reminders.txt`)
- macOS 安装脚本(目前只有 Linux + Windows)
- 响应改写支持(目前主要管请求改写)

---

## 致谢 & 局限

- 基于 [Anthropic Claude Code](https://github.com/anthropics/claude-code) 的 npm 包
- 不与 Anthropic 官方关联;**仅供学习、调试、本地实验用途**
- **限制**:Claude Code 2.1.113+ 切到 SEA 后无法 hook;通过本工具的 `lock-claude` 锁回 2.1.112 是当前唯一可行路径
- **不要**滥用 `HEADER_AUTH_REPLACE` 替换他人 token;只对自己的 API key / OAuth token 改写
- 改写规则可能违反 Anthropic 的 Acceptable Use Policy,使用时自行判断

---

**版本**:V3.2.0
**仓库**:https://github.com/ziren28/node_helper
**License**:MIT
