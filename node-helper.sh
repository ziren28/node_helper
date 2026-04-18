#!/usr/bin/env bash
# ============================================================
# node_helper V3.2 · Linux 一键管理脚本(菜单版)
#
# 功能:安装 / 更新 / 状态 / 配置 / 卸载 / 脚本自更新
# 依赖文件(intercept.cjs / .mjs / package.json / .env.example / prompts/)
# 优先从同目录读;没有就从 GitHub 自动下载
#
# 仓库:  https://github.com/ziren28/node_helper
# 分支:  main
#
# 交互用法:
#   bash node-helper.sh                            # 显示菜单
#
# 命令行用法:
#   bash node-helper.sh install [--cjs|--esm] [--global|--wrapper]
#   bash node-helper.sh update                     # 重拉最新依赖 + 更新安装
#   bash node-helper.sh status                     # 状态
#   bash node-helper.sh configure                  # 打开 $EDITOR 编辑 .env
#   bash node-helper.sh uninstall [-y]             # 卸载
#   bash node-helper.sh self-update                # 只更新本脚本
#   bash node-helper.sh help
# ============================================================
set -uo pipefail

# ============================================================
#  全局配置
# ============================================================
VERSION="3.2.0"
REPO_OWNER="ziren28"
REPO_NAME="node_helper"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

# Claude Code 版本锁定:2.1.112 是最后一个 JS 版
# 2.1.113+ 改成 SEA 原生二进制,NODE_OPTIONS 会被忽略,我们的 hook 失效
CLAUDE_CODE_VERSION="2.1.112"
CLAUDE_CODE_TARBALL_URL="$RAW_BASE/vendor/claude-code-${CLAUDE_CODE_VERSION}.tgz"
CLAUDE_CODE_NPM_FALLBACK="@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
CRON_FILE="/etc/cron.daily/node-helper-claude-lock"
CRON_LOG="/var/log/node-helper-claude-lock.log"

# 默认下载路径列表(相对于 RAW_BASE)
REMOTE_FILES=(
  "intercept.cjs"
  "intercept.mjs"
  "package.json"
  ".env.example"
  "prompts/minimal_strip.txt"
  "prompts/strip_reminders.txt"
  "prompts/system.txt"
  "prompts/system_patterns.txt"
)

# 本机路径
# root 默认 /usr/local/bin(在 /usr/bin 前,天然生效);普通用户 ~/.local/bin
if [[ -n "${NODE_HELPER_BIN:-}" ]]; then
  BIN_DIR="$NODE_HELPER_BIN"
elif [[ "$(id -u 2>/dev/null)" == "0" ]]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
PREFIX="${NODE_HELPER_PREFIX:-$HOME/.local/share/node-helper}"
WRAPPER="$BIN_DIR/claude"
PROFILE="$HOME/.profile"
CACHE_DIR="$HOME/.cache/node-helper-dl"
MARK_BEGIN="# >>> node_helper V3.2 >>>"
MARK_END="# <<< node_helper V3.2 <<<"

# TTY 颜色
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'
  C_TITLE=$'\033[1;36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_WARN=''; C_TITLE=''; C_DIM=''; C_RST=''
fi
OK="${C_OK}✓${C_RST}"; BAD="${C_ERR}✗${C_RST}"; WARN="${C_WARN}⚠${C_RST}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
SELF_URL="$RAW_BASE/node-helper.sh"

# ============================================================
#  基础工具
# ============================================================
log()  { echo "$*"; }
hr()   { echo "${C_DIM}────────────────────────────────────────────────────────${C_RST}"; }
die()  { echo "${BAD} $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

# ============================================================
#  HTTP 下载(curl 优先,wget 兜底)
# ============================================================
http_get() {
  local url="$1" out="$2"
  if require_cmd curl; then
    curl -fsSL --connect-timeout 10 -o "$out" "$url"
  elif require_cmd wget; then
    wget -q -O "$out" "$url"
  else
    die "既没有 curl 也没有 wget,不能下载。请先 apt/yum install curl"
  fi
}

http_get_str() {
  local url="$1"
  if require_cmd curl; then
    curl -fsSL --connect-timeout 10 "$url"
  elif require_cmd wget; then
    wget -q -O - "$url"
  else
    return 1
  fi
}

# ============================================================
#  源文件定位
#    1) 脚本同目录  (scripts/linux + 依赖,自包含发行包)
#    2) 仓库根       (开发模式:v3/ 下面)
#    3) GitHub 下载  (纯脚本,现场拉取)
# ============================================================
locate_source() {
  SRC_MODE=""
  SRC_DIR=""
  if [[ -f "$SCRIPT_DIR/intercept.cjs" ]]; then
    SRC_MODE="local-self"
    SRC_DIR="$SCRIPT_DIR"
  elif [[ -f "$SCRIPT_DIR/../../intercept.cjs" ]]; then
    SRC_MODE="local-repo"
    SRC_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
  else
    SRC_MODE="remote"
    SRC_DIR="$CACHE_DIR/src"
  fi
}

# 把依赖文件放到 $1(目标目录);优先用本地源,找不到就下载
materialize_sources() {
  local dest="$1"
  mkdir -p "$dest" "$dest/prompts"

  if [[ "$SRC_MODE" != "remote" ]]; then
    # 本地源,直接 cp
    for f in "${REMOTE_FILES[@]}"; do
      if [[ -f "$SRC_DIR/$f" ]]; then
        mkdir -p "$dest/$(dirname "$f")"
        cp -f "$SRC_DIR/$f" "$dest/$f"
      else
        log "  ${WARN} 本地没有 $f,跳过"
      fi
    done
  else
    # 远程:从 GitHub 拉
    log "${C_DIM}从 GitHub 下载:${C_RST} $RAW_BASE"
    for f in "${REMOTE_FILES[@]}"; do
      mkdir -p "$dest/$(dirname "$f")"
      if http_get "$RAW_BASE/$f" "$dest/$f"; then
        log "  ${OK} $f"
      else
        log "  ${BAD} $f 下载失败"
        return 1
      fi
    done
  fi
}

# ============================================================
#  版本检测
# ============================================================
read_local_version() {
  local pj="$PREFIX/package.json"
  [[ -f "$pj" ]] || { echo ""; return; }
  # 纯 bash 解析 "version" 字段
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" 2>/dev/null \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

read_remote_version() {
  local pj
  pj=$(http_get_str "$RAW_BASE/package.json" 2>/dev/null) || { echo ""; return; }
  echo "$pj" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# ============================================================
#  [install] 真正执行安装;被菜单 / 命令行共用
# ============================================================
do_install() {
  local MODE="wrapper" LOADER="esm"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wrapper) MODE="wrapper"; shift;;
      --global)  MODE="global";  shift;;
      --esm)     LOADER="esm"; shift;;
      --cjs)     LOADER="cjs"; shift;;
      --prefix)  PREFIX="$2"; shift 2;;
      --bin)     BIN_DIR="$2"; WRAPPER="$BIN_DIR/claude"; shift 2;;
      *) die "install: 未知参数 $1";;
    esac
  done

  require_cmd node || die "需要 Node.js ≥ 18"
  local nmaj; nmaj=$(node -p "process.versions.node.split('.')[0]")
  [[ "$nmaj" -lt 18 ]] && die "Node 版本太低($nmaj),需要 ≥ 18"

  locate_source
  log ""
  log "${C_TITLE}━━━ 安装 ━━━${C_RST}"
  log "  模式:      $MODE"
  log "  加载器:    $LOADER"
  case "$SRC_MODE" in
    local-self) log "  源位置:    本地同目录" ;;
    local-repo) log "  源位置:    本地仓库($SRC_DIR)" ;;
    remote)     log "  源位置:    GitHub 远程" ;;
  esac
  log "  安装到:    $PREFIX"
  [[ "$MODE" == "wrapper" ]] && log "  wrapper:   $WRAPPER"
  log ""

  materialize_sources "$PREFIX" || die "依赖文件未齐备"

  # .env 存在就保留,没有就从模板生成
  if [[ ! -f "$PREFIX/.env" && -f "$PREFIX/.env.example" ]]; then
    cp "$PREFIX/.env.example" "$PREFIX/.env"
    log "  ${OK} 从 .env.example 生成默认 .env"
  fi

  # 计算 NODE_OPTIONS flag
  local FLAG
  if [[ "$LOADER" == "esm" && -f "$PREFIX/intercept.mjs" ]]; then
    FLAG="--import=file://$PREFIX/intercept.mjs"
  else
    FLAG="--require=$PREFIX/intercept.cjs"
  fi

  case "$MODE" in
  wrapper)
    mkdir -p "$BIN_DIR"
    cat > "$WRAPPER" << WRAPEOF
#!/usr/bin/env bash
# node_helper V3.2 wrapper · 临时禁用: CLAUDE_INTERCEPT=off claude ...
if [[ "\${CLAUDE_INTERCEPT:-on}" != "off" ]]; then
  export NODE_OPTIONS="$FLAG \${NODE_OPTIONS:-}"
fi
SELF=\$(realpath "\$0" 2>/dev/null || readlink -f "\$0")
REAL=""
IFS=':' read -ra PATHS <<< "\$PATH"
for d in "\${PATHS[@]}"; do
  for n in claude claude.cmd claude.sh; do
    c="\$d/\$n"
    if [[ -x "\$c" && "\$(realpath "\$c" 2>/dev/null || echo "\$c")" != "\$SELF" ]]; then
      REAL="\$c"; break 2
    fi
  done
done
[[ -z "\$REAL" ]] && { echo "[node_helper] PATH 找不到真正的 claude" >&2; exit 127; }
exec "\$REAL" "\$@"
WRAPEOF
    chmod +x "$WRAPPER"
    log ""
    log "${OK} 已装 wrapper: $WRAPPER"
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
      log "${WARN} $BIN_DIR 不在 PATH,追加到 ~/.bashrc 或 ~/.zshrc:"
      log "     export PATH=\"$BIN_DIR:\$PATH\""
    fi
    ;;

  global)
    [[ -f "$PROFILE" ]] && sed -i.bak.$(date +%s) "/$MARK_BEGIN/,/$MARK_END/d" "$PROFILE"
    {
      echo ""
      echo "$MARK_BEGIN"
      echo "# intercept.cjs 内部有 gate,只在 Claude 进程激活,其它 Node 0 影响"
      echo "export NODE_OPTIONS=\"$FLAG \${NODE_OPTIONS:-}\""
      echo "$MARK_END"
    } >> "$PROFILE"
    log ""
    log "${OK} 已写入 $PROFILE(下次登录 / source ~/.profile 后生效)"
    ;;
  esac

  log ""
  log "${OK} 安装完成(版本 $VERSION)"
}

# ============================================================
#  [update]  = 拉最新依赖 + 再装一次
# ============================================================
do_update() {
  log ""
  log "${C_TITLE}━━━ 检查更新 ━━━${C_RST}"
  local local_v remote_v
  local_v=$(read_local_version)
  log "  本地版本:  ${local_v:-(未安装)}"
  remote_v=$(read_remote_version)
  if [[ -z "$remote_v" ]]; then
    log "  ${WARN} 无法拉到远程 package.json(网络/仓库问题)"
  else
    log "  远程版本:  $remote_v"
    if [[ -n "$local_v" && "$local_v" == "$remote_v" ]]; then
      log "  ${OK} 已是最新,无需更新"
      confirm "仍然强制重装?" || return 0
    fi
  fi

  # 强制远程下载
  SRC_MODE="remote"; SRC_DIR="$CACHE_DIR/src"
  mkdir -p "$SRC_DIR"
  materialize_sources "$SRC_DIR" || die "依赖下载失败"

  # 再用本地 cp 方式装(避免重复下载)
  cp -rf "$SRC_DIR"/* "$PREFIX/" 2>/dev/null || true

  # 刷新 wrapper(保持原模式)
  if [[ -f "$WRAPPER" ]] && grep -q "node_helper" "$WRAPPER"; then
    log "  ${OK} 更新完成,wrapper 保留"
  else
    log "  ${OK} 文件更新完成,未检测到 wrapper,跳过包装器更新"
  fi
}

# ============================================================
#  [status]
# ============================================================
do_status() {
  log ""
  log "${C_TITLE}━━━ 状态 ━━━${C_RST}"

  log "[1] 安装目录"
  if [[ -d "$PREFIX" ]]; then
    log "    $OK $PREFIX"
    for f in intercept.cjs intercept.mjs package.json .env; do
      [[ -e "$PREFIX/$f" ]] && log "      $OK $f" || log "      $BAD $f"
    done
    [[ -d "$PREFIX/prompts" ]] \
      && log "      $OK prompts/ ($(ls "$PREFIX/prompts" 2>/dev/null | wc -l) 个)" \
      || log "      $WARN prompts/ 缺失"
    local lv; lv=$(read_local_version)
    [[ -n "$lv" ]] && log "      版本:  $lv"
  else
    log "    $BAD 未安装"
  fi

  log ""
  log "[2] wrapper"
  if [[ -f "$WRAPPER" ]] && grep -q "node_helper" "$WRAPPER"; then
    log "    $OK $WRAPPER"
    grep -oE 'NODE_OPTIONS="[^"]+"' "$WRAPPER" | head -1 | sed "s|^|      ${C_DIM}|;s|$|${C_RST}|"
  else
    log "    ${C_DIM}(未装)${C_RST}"
  fi

  log ""
  log "[3] 全局 ~/.profile 注入"
  if grep -q "$MARK_BEGIN" "$PROFILE" 2>/dev/null; then
    log "    $OK 有注入块"
  else
    log "    ${C_DIM}(无)${C_RST}"
  fi

  log ""
  log "[4] PATH / which claude"
  local wc; wc=$(command -v claude 2>/dev/null || echo "")
  if [[ -n "$wc" ]]; then
    log "    which claude → $wc"
    if [[ -f "$WRAPPER" ]]; then
      local a b
      a=$(realpath "$wc" 2>/dev/null || echo "$wc")
      b=$(realpath "$WRAPPER" 2>/dev/null || echo "$WRAPPER")
      [[ "$a" == "$b" ]] && log "      $OK 是 node_helper" || log "      $WARN 不是 node_helper"
    fi
  else
    log "    $BAD PATH 无 claude"
  fi

  log ""
  log "[5] 伴随服务端口"
  local ports
  if require_cmd ss; then
    ports=$(ss -lntp 2>/dev/null | grep -E ':(8787|8799) ' || true)
  else
    ports=$(netstat -lntp 2>/dev/null | grep -E ':(8787|8799) ' || true)
  fi
  [[ -n "$ports" ]] && echo "$ports" | sed 's/^/    /' || log "    ${C_DIM}(8787/8799 未监听)${C_RST}"

  log ""
  log "[6] 版本对比"
  local lv rv
  lv=$(read_local_version)
  rv=$(read_remote_version)
  log "    本地:  ${lv:-(未安装)}"
  log "    远程:  ${rv:-(拉取失败)}"
  if [[ -n "$lv" && -n "$rv" && "$lv" != "$rv" ]]; then
    log "    $WARN 有更新:运行菜单第 2 项 或  bash $0 update"
  elif [[ -n "$lv" && "$lv" == "$rv" ]]; then
    log "    $OK 已是最新"
  fi
  log ""
}

# ============================================================
#  [configure]
# ============================================================
do_configure() {
  local envf="$PREFIX/.env"
  if [[ ! -f "$envf" ]]; then
    if [[ -f "$PREFIX/.env.example" ]]; then
      cp "$PREFIX/.env.example" "$envf"
      log "${OK} 已从模板生成 $envf"
    else
      die "$envf 不存在且无模板,先安装"
    fi
  fi
  local EDIT="${EDITOR:-$(command -v nano || command -v vi || command -v vim)}"
  [[ -z "$EDIT" ]] && die "未找到编辑器,请先设 \$EDITOR 或装 nano/vi"
  log "${OK} 打开: $EDIT $envf"
  "$EDIT" "$envf"
}

# ============================================================
#  [uninstall]
# ============================================================
do_uninstall() {
  ASSUME_YES=0
  for a in "$@"; do
    case "$a" in -y|--yes) ASSUME_YES=1;; esac
  done

  log ""
  log "${C_TITLE}━━━ 卸载 ━━━${C_RST}"

  if [[ -f "$WRAPPER" ]] && grep -q "node_helper" "$WRAPPER"; then
    confirm "删 wrapper  $WRAPPER ?" && { rm -f "$WRAPPER"; log "  $OK 已删"; } || log "  skip"
  fi

  if grep -q "$MARK_BEGIN" "$PROFILE" 2>/dev/null; then
    if confirm "从 $PROFILE 移除 NODE_OPTIONS 注入?"; then
      cp "$PROFILE" "$PROFILE.bak.$(date +%Y%m%d-%H%M%S)"
      sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$PROFILE"
      log "  $OK 已移除(备份 .bak.xxx)"
    fi
  fi

  if [[ -d "$PREFIX" ]]; then
    [[ -f "$PREFIX/.env" ]] && log "  ${WARN} $PREFIX/.env 可能含你的配置"
    confirm "删 $PREFIX ?" && { rm -rf "$PREFIX"; log "  $OK 已删"; } || log "  skip"
  fi

  # 日志
  local logs=()
  for f in /tmp/node-helper-intercept.jsonl "$HOME/.cache/node-helper-intercept.jsonl"; do
    [[ -f "$f" ]] && logs+=("$f")
  done
  if [[ ${#logs[@]} -gt 0 ]]; then
    confirm "清理 intercept 日志(${#logs[@]} 个)?" && { rm -f "${logs[@]}"; log "  $OK 已清"; }
  fi

  # 下载缓存
  [[ -d "$CACHE_DIR" ]] && confirm "清下载缓存 $CACHE_DIR ?" && rm -rf "$CACHE_DIR"

  # cron 锁
  if [[ -f "$CRON_FILE" ]] && grep -q "node_helper" "$CRON_FILE" 2>/dev/null; then
    confirm "删 Claude 版本锁 cron($CRON_FILE)?" && rm -f "$CRON_FILE" && log "  $OK 已删"
  fi
  # 用户级 cron 条目
  if crontab -l 2>/dev/null | grep -q "node-helper-claude-lock"; then
    confirm "清用户 crontab 里的 node-helper-claude-lock 条目?" && \
      (crontab -l 2>/dev/null | grep -v "node-helper-claude-lock" | crontab -) && log "  $OK 已清"
  fi

  log ""
  log "卸载完成。which claude 当前 → $(command -v claude 2>/dev/null || echo '(无)')"
}

# ============================================================
#  [lock-claude] 把 Claude Code 锁到 2.1.112(最后一个 JS 版)
#  + 装每天检查、偏离就回滚的 cron
#
#  为什么 2.1.113+ 不能用:
#    从 2.1.113 起 Anthropic 把包切成 SEA 原生二进制,
#    Node 的 NODE_OPTIONS / --import / --require 全被锁死,
#    我们所有 hook 方案对那个版本 无效。
# ============================================================
_claude_installed_version() {
  local pj=/usr/lib/node_modules/@anthropic-ai/claude-code/package.json
  [[ -f "$pj" ]] || { echo ""; return; }
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

do_lock_claude() {
  require_cmd npm || die "需要 npm"

  log ""
  log "${C_TITLE}━━━ 锁定 Claude Code 到 $CLAUDE_CODE_VERSION ━━━${C_RST}"

  local cur
  cur=$(_claude_installed_version)
  log "  当前:  ${cur:-(未装)}"
  log "  目标:  $CLAUDE_CODE_VERSION"

  if [[ "$cur" == "$CLAUDE_CODE_VERSION" ]]; then
    log "  $OK 已是目标版本,跳过重装"
  else
    log ""
    log "[1/2] 装 Claude Code $CLAUDE_CODE_VERSION"

    # 如果装了其它版本,先卸
    if [[ -n "$cur" ]]; then
      npm uninstall -g @anthropic-ai/claude-code 2>&1 | sed 's/^/    /' | tail -3
    fi

    # 优先从本仓库的 vendor/ 拖 tarball(版本锁死、抗 Anthropic 下架);
    # 失败再走 npm registry
    local tarball="$CACHE_DIR/claude-code-${CLAUDE_CODE_VERSION}.tgz"
    mkdir -p "$CACHE_DIR"
    if http_get "$CLAUDE_CODE_TARBALL_URL" "$tarball" 2>/dev/null && [[ -s "$tarball" ]]; then
      log "  ${OK} 已从 GitHub vendor/ 拉 tarball ($(du -h "$tarball" | cut -f1))"
      npm install -g "$tarball" 2>&1 | sed 's/^/    /' | tail -3
    else
      log "  ${WARN} GitHub vendor 拉不到 tarball,回退到 npm registry"
      npm install -g "$CLAUDE_CODE_NPM_FALLBACK" 2>&1 | sed 's/^/    /' | tail -3
    fi

    cur=$(_claude_installed_version)
    if [[ "$cur" != "$CLAUDE_CODE_VERSION" ]]; then
      log "  ${BAD} 装完后版本是 ${cur:-(空)},目标是 $CLAUDE_CODE_VERSION"
      die "Claude Code 版本锁定失败"
    fi
    log "  ${OK} Claude Code $CLAUDE_CODE_VERSION 已装"
  fi

  log ""
  log "[2/2] 安装防漂移 cron"

  # 需要 root 才能写 /etc/cron.daily,非 root 用户 crontab
  if [[ "$(id -u 2>/dev/null)" == "0" ]] && [[ -d /etc/cron.daily ]]; then
    cat > "$CRON_FILE" << CRONEOF
#!/bin/sh
# node_helper · Claude Code 版本锁 —— 每天 cron.daily 检查一次,偏离就回滚
# 目标版本:$CLAUDE_CODE_VERSION(最后一个 JS 版,2.1.113+ 是 SEA 不能 hook)
set -e
LOG="$CRON_LOG"
TARGET="$CLAUDE_CODE_VERSION"
PKG_JSON=/usr/lib/node_modules/@anthropic-ai/claude-code/package.json

# 从 package.json 读版本,绕过 hook 避免 stderr 污染
if [ -f "\$PKG_JSON" ]; then
  CUR=\$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "\$PKG_JSON" | head -1 | sed 's/.*"\([^"]*\)"\$/\1/')
else
  CUR=""
fi

if [ "\$CUR" != "\$TARGET" ]; then
  echo "[\$(date -Iseconds)] drift: \${CUR:-none} -> reinstalling \$TARGET" >> "\$LOG"
  /usr/bin/npm uninstall -g @anthropic-ai/claude-code >> "\$LOG" 2>&1 || true
  TARBALL="$CACHE_DIR/claude-code-\$TARGET.tgz"
  if [ -f "\$TARBALL" ]; then
    /usr/bin/npm install -g "\$TARBALL" >> "\$LOG" 2>&1
  else
    /usr/bin/npm install -g "@anthropic-ai/claude-code@\$TARGET" >> "\$LOG" 2>&1
  fi
  NEW=\$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "\$PKG_JSON" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"\$/\1/' || echo "?")
  echo "[\$(date -Iseconds)] now: \$NEW" >> "\$LOG"
fi
CRONEOF
    chmod +x "$CRON_FILE"
    log "  $OK 已装: $CRON_FILE"
    log "  ${C_DIM}日志:$CRON_LOG${C_RST}"
    # 干跑一次验证
    if sh -n "$CRON_FILE" 2>/dev/null; then
      log "  $OK 脚本语法检查通过"
    fi
  else
    # 非 root:用户级 crontab
    log "  ${WARN} 非 root,改用用户 crontab"
    local user_script="$PREFIX/claude-lock.sh"
    cat > "$user_script" << USEREOF
#!/bin/sh
# node_helper · Claude Code 版本锁(用户级)
PKG_JSON=/usr/lib/node_modules/@anthropic-ai/claude-code/package.json
[ -f "\$PKG_JSON" ] || exit 0
CUR=\$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "\$PKG_JSON" | head -1 | sed 's/.*"\([^"]*\)"\$/\1/')
[ "\$CUR" = "$CLAUDE_CODE_VERSION" ] || npm install -g "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" >> "\$HOME/.cache/claude-lock.log" 2>&1
USEREOF
    chmod +x "$user_script"
    (crontab -l 2>/dev/null | grep -v node-helper-claude-lock; \
     echo "0 3 * * * $user_script  # node-helper-claude-lock") | crontab -
    log "  $OK 已装用户 crontab(每天 03:00 检查)"
  fi

  log ""
  log "${OK} 完成。claude $(command -v claude) → $(claude --version 2>/dev/null | tail -1)"
}


# ============================================================
#  [reset] 强制重置:清状态 -> 强制从 GitHub 下载 -> 重装 -> 激活
#  无交互,适合一键修复挂载失败的情况
# ============================================================
do_reset() {
  local MODE="wrapper" LOADER="esm" LOCK_CLAUDE=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global)     MODE="global"; shift;;
      --cjs)        LOADER="cjs"; shift;;
      --esm)        LOADER="esm"; shift;;
      --bin)        BIN_DIR="$2"; WRAPPER="$BIN_DIR/claude"; shift 2;;
      --prefix)     PREFIX="$2"; shift 2;;
      --no-claude)  LOCK_CLAUDE=0; shift;;   # 不锁 Claude Code 版本(专家模式)
      *) log "${WARN} 忽略未知参数: $1"; shift;;
    esac
  done

  require_cmd node || die "需要 Node.js ≥ 18"

  log ""
  log "${C_TITLE}━━━ 强制重置(clean + remote pull + reinstall) ━━━${C_RST}"
  log "  目标安装到:  $PREFIX"
  log "  wrapper →    $WRAPPER"
  log "  模式:        $MODE  +  $LOADER"
  log ""

  # [1] 清所有已知 wrapper 位置
  log "${C_TITLE}[1/6]${C_RST} 清旧 wrapper"
  local rm_count=0
  for loc in \
      "$HOME/.local/bin/claude" \
      "/usr/local/bin/claude" \
      "/usr/bin/claude-helper" \
      "$WRAPPER"; do
    if [[ -f "$loc" ]] && grep -q "node_helper" "$loc" 2>/dev/null; then
      rm -f "$loc" && log "  ${OK} 删 $loc"
      rm_count=$((rm_count + 1))
    fi
  done
  [[ $rm_count -eq 0 ]] && log "  ${C_DIM}(无)${C_RST}"

  # [2] 清 ~/.profile 注入
  log "${C_TITLE}[2/6]${C_RST} 清 $PROFILE 注入块"
  if grep -q "$MARK_BEGIN" "$PROFILE" 2>/dev/null; then
    cp "$PROFILE" "$PROFILE.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$PROFILE"
    log "  ${OK} 已移除(原文件备份 .bak.xxx)"
  else
    log "  ${C_DIM}(无)${C_RST}"
  fi

  # [3] 清安装目录
  log "${C_TITLE}[3/6]${C_RST} 清安装目录 $PREFIX"
  if [[ -d "$PREFIX" ]]; then
    # 保留 .env(可能有用户配的 token / 规则)
    local had_env=""
    if [[ -f "$PREFIX/.env" ]]; then
      had_env=$(mktemp)
      cp "$PREFIX/.env" "$had_env"
      log "  ${C_DIM}(保留 .env 备份到 $had_env)${C_RST}"
    fi
    rm -rf "$PREFIX"
    log "  ${OK} 已删"
    if [[ -n "$had_env" ]]; then
      mkdir -p "$PREFIX"
      cp "$had_env" "$PREFIX/.env"
      rm -f "$had_env"
      log "  ${OK} 已还原旧 .env"
    fi
  else
    log "  ${C_DIM}(不存在)${C_RST}"
  fi

  # [4] 清下载缓存
  log "${C_TITLE}[4/6]${C_RST} 清下载缓存 $CACHE_DIR"
  rm -rf "$CACHE_DIR"
  log "  ${OK} 已清"

  # [5] 强制从 GitHub 下载
  log "${C_TITLE}[5/6]${C_RST} 从 GitHub 强制下载"
  SRC_MODE="remote"
  SRC_DIR="$CACHE_DIR/src"
  mkdir -p "$SRC_DIR"
  materialize_sources "$SRC_DIR" || die "下载失败,请检查网络和仓库路径:$RAW_BASE"
  mkdir -p "$PREFIX"
  # 用 cp -a 保留时间戳,但不覆盖已还原的 .env
  (cd "$SRC_DIR" && find . -type f | while read -r f; do
    target="$PREFIX/${f#./}"
    # .env 已还原就不覆盖
    if [[ "$f" == "./.env" && -f "$target" ]]; then continue; fi
    mkdir -p "$(dirname "$target")"
    cp -f "$f" "$target"
  done)
  [[ ! -f "$PREFIX/.env" && -f "$PREFIX/.env.example" ]] && cp "$PREFIX/.env.example" "$PREFIX/.env"
  log "  ${OK} 文件已全部就位"

  # [6] 装 wrapper + 激活
  log "${C_TITLE}[6/6]${C_RST} 装 wrapper + 立即生效"
  local FLAG
  if [[ "$LOADER" == "esm" && -f "$PREFIX/intercept.mjs" ]]; then
    FLAG="--import=file://$PREFIX/intercept.mjs"
  else
    FLAG="--require=$PREFIX/intercept.cjs"
  fi

  case "$MODE" in
  wrapper)
    mkdir -p "$BIN_DIR"
    cat > "$WRAPPER" << WRAPEOF
#!/usr/bin/env bash
if [[ "\${CLAUDE_INTERCEPT:-on}" != "off" ]]; then
  export NODE_OPTIONS="$FLAG \${NODE_OPTIONS:-}"
fi
SELF=\$(realpath "\$0" 2>/dev/null || readlink -f "\$0")
REAL=""
IFS=':' read -ra PATHS <<< "\$PATH"
for d in "\${PATHS[@]}"; do
  for n in claude claude.cmd claude.sh; do
    c="\$d/\$n"
    if [[ -x "\$c" && "\$(realpath "\$c" 2>/dev/null || echo "\$c")" != "\$SELF" ]]; then
      REAL="\$c"; break 2
    fi
  done
done
[[ -z "\$REAL" ]] && { echo "[node_helper] PATH 找不到真正的 claude" >&2; exit 127; }
exec "\$REAL" "\$@"
WRAPEOF
    chmod +x "$WRAPPER"
    log "  ${OK} wrapper: $WRAPPER"
    ;;
  global)
    {
      echo ""
      echo "$MARK_BEGIN"
      echo "export NODE_OPTIONS=\"$FLAG \${NODE_OPTIONS:-}\""
      echo "$MARK_END"
    } >> "$PROFILE"
    log "  ${OK} 已写 $PROFILE"
    ;;
  esac

  # 清 bash 命令缓存(只影响本 subshell,用户需自己再做一次)
  hash -r 2>/dev/null || true

  echo ""
  log "${C_TITLE}━━━ 完成 ━━━${C_RST}"
  local resolved
  resolved=$(command -v claude 2>/dev/null || echo "(PATH 无 claude)")
  log "  which claude  →  $resolved"

  if [[ "$resolved" == "$WRAPPER" ]]; then
    log "  ${OK} 包装器已生效"
  else
    log "  ${WARN} 当前 shell 命令缓存未刷新或 $BIN_DIR 不在 PATH 最前"
    log ""
    log "  在你的 shell 里执行这一行,立即生效:"
    log ""
    log "    ${C_TITLE}export PATH=\"$BIN_DIR:\$PATH\" && hash -r${C_RST}"
    log ""
    log "  或直接开新终端。"
  fi
  log ""

  # 默认连 Claude Code 版本也一起锁(reset 的语义就是"确保一切可用")
  if [[ "$LOCK_CLAUDE" == "1" ]]; then
    do_lock_claude
  else
    log "  ${C_DIM}(--no-claude:跳过 Claude Code 版本锁)${C_RST}"
  fi

  log ""
  log "  最终验证:  CLAUDE_INTERCEPT_DEBUG=1 claude --version 2>&1 | head -3"
  log "  看到 '[ic v3] active' 一行 + 版本 $CLAUDE_CODE_VERSION = 完全成功"
}


# ============================================================
#  [self-update]  只更新本脚本
# ============================================================
do_self_update() {
  log ""
  log "${C_TITLE}━━━ 自更新 ━━━${C_RST}"
  log "  当前脚本:  $SCRIPT_PATH"
  local tmp="$CACHE_DIR/node-helper.sh.new"
  mkdir -p "$CACHE_DIR"
  if ! http_get "$SELF_URL" "$tmp"; then
    die "下载 $SELF_URL 失败"
  fi
  if cmp -s "$SCRIPT_PATH" "$tmp" 2>/dev/null; then
    log "  $OK 本脚本已是最新"
    rm -f "$tmp"
    return 0
  fi
  log "  ${WARN} 检测到新版本"
  if confirm "用新版本替换 $SCRIPT_PATH ?"; then
    cp "$SCRIPT_PATH" "$SCRIPT_PATH.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    log "  $OK 已更新(原文件备份 .bak.xxx)"
    log "  重新运行:  bash $SCRIPT_PATH"
  else
    rm -f "$tmp"
    log "  skip"
  fi
}

# ============================================================
#  交互菜单
# ============================================================
show_banner() {
  clear 2>/dev/null || printf '\n\n'
  echo ""
  echo "${C_TITLE}╔══════════════════════════════════════════════════════╗${C_RST}"
  echo "${C_TITLE}║   node_helper V${VERSION} · Claude Code 拦截与改写         ║${C_RST}"
  echo "${C_TITLE}║   github.com/${REPO_OWNER}/${REPO_NAME}${C_RST}                    "
  echo "${C_TITLE}╚══════════════════════════════════════════════════════╝${C_RST}"
  echo ""

  # 简版状态
  local lv inst_mark wrapper_mark
  lv=$(read_local_version)
  if [[ -d "$PREFIX" && -n "$lv" ]]; then
    inst_mark="${OK} 已安装  (v$lv,$PREFIX)"
  else
    inst_mark="${C_DIM}未安装${C_RST}"
  fi
  if [[ -f "$WRAPPER" ]] && grep -q "node_helper" "$WRAPPER"; then
    wrapper_mark="${OK} $WRAPPER"
  else
    wrapper_mark="${C_DIM}(未装)${C_RST}"
  fi
  echo "  安装状态:  $inst_mark"
  echo "  wrapper :  $wrapper_mark"
  echo ""
}

show_menu() {
  show_banner
  hr
  echo "   1) 安装 / 重装         (首次安装或覆盖装)"
  echo "   2) 更新                (检查远程版本,拉最新)"
  echo "   3) 查看详细状态"
  echo "   4) 编辑 .env 配置"
  echo "   5) 卸载"
  echo ""
  echo "   7) ${C_TITLE}强制重置${C_RST}          (清 + 拉 + 重装 + 激活 + 锁 Claude $CLAUDE_CODE_VERSION)"
  echo "   8) 只锁 Claude Code    (装/回滚到 $CLAUDE_CODE_VERSION + 加 cron 防漂移)"
  echo "   6) 自更新此脚本        (从 GitHub 拉最新的 node-helper.sh)"
  echo ""
  echo "   0) 退出"
  hr
  read -r -p "  请选择 [0-8]: " choice
  echo ""
  case "$choice" in
    1) do_install ;;
    2) do_update ;;
    3) do_status ;;
    4) do_configure ;;
    5) do_uninstall ;;
    6) do_self_update ;;
    7) do_reset ;;
    8) do_lock_claude ;;
    0|q|Q) log "再见"; exit 0 ;;
    *) log "${BAD} 无效选择"; sleep 1 ;;
  esac
  echo ""
  read -r -p "  按回车回主菜单 ..."
  show_menu
}

# ============================================================
#  帮助
# ============================================================
usage() {
  sed -n '2,23p' "$0" | sed 's/^# \?//'
}

# ============================================================
#  分发
# ============================================================
main() {
  # 无参数 → 交互菜单
  if [[ $# -eq 0 ]]; then
    show_menu
    return
  fi

  local cmd="$1"; shift
  case "$cmd" in
    install)             do_install "$@" ;;
    update|upgrade)      do_update ;;
    reset|fresh|force)   do_reset "$@" ;;
    lock-claude|lock)    do_lock_claude ;;
    status|st)           do_status ;;
    configure|config)    do_configure ;;
    uninstall|remove)    do_uninstall "$@" ;;
    self-update)         do_self_update ;;
    menu)                show_menu ;;
    help|-h|--help)      usage ;;
    version|-v|--version) echo "node_helper v$VERSION"; exit 0 ;;
    *) log "${BAD} 未知子命令: $cmd"; usage; exit 2 ;;
  esac
}

main "$@"
