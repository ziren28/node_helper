#!/usr/bin/env bash
# ============================================================
# node_helper V3.2 · Linux 管理脚本(单文件)
#
# 用法:
#   bash node-helper.sh install [options]     安装(默认子命令,省略也行)
#   bash node-helper.sh status                查看状态
#   bash node-helper.sh uninstall [-y]        卸载
#   bash node-helper.sh help                  显示帮助
#
# 安装选项:
#   --wrapper      只挂 `claude` 命令(默认,推荐)
#   --global       写 ~/.profile,所有 node 进程都挂(靠 intercept 门禁过滤)
#   --esm          加载器用 intercept.mjs(默认)
#   --cjs          加载器用 intercept.cjs(老兼容)
#   --prefix DIR   安装目录,默认 ~/.local/share/node-helper
#   --bin DIR      wrapper 放哪,默认 ~/.local/bin
# ============================================================
set -uo pipefail

# ---------- 共享变量 / 路径 ----------
PREFIX_DEFAULT="$HOME/.local/share/node-helper"
BIN_DEFAULT="$HOME/.local/bin"
PROFILE="$HOME/.profile"
MARK_BEGIN="# >>> node_helper V3.2 >>>"
MARK_END="# <<< node_helper V3.2 <<<"

PREFIX="${NODE_HELPER_PREFIX:-$PREFIX_DEFAULT}"
BIN_DIR="${NODE_HELPER_BIN:-$BIN_DEFAULT}"
WRAPPER="$BIN_DIR/claude"

# 颜色(tty 才开)
if [[ -t 1 ]]; then
  OK=$'\033[32m✓\033[0m'; BAD=$'\033[31m✗\033[0m'
  WARN=$'\033[33m⚠\033[0m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  OK='[ok]'; BAD='[x]'; WARN='[!]'; DIM=''; RST=''
fi

# ---------- 通用工具 ----------
log()  { echo "$*"; }
die()  { echo "[x] $*" >&2; exit 1; }
confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \?//'
}

# ============================================================
#  cmd_install
# ============================================================
cmd_install() {
  local MODE="wrapper" LOADER="esm"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wrapper) MODE="wrapper"; shift;;
      --global)  MODE="global";  shift;;
      --esm)     LOADER="esm"; shift;;
      --cjs)     LOADER="cjs"; shift;;
      --prefix)  PREFIX="$2"; shift 2;;
      --bin)     BIN_DIR="$2"; WRAPPER="$BIN_DIR/claude"; shift 2;;
      *)         die "install: 未知参数 $1";;
    esac
  done

  # 环境检查
  command -v node >/dev/null || die "需要 Node.js ≥ 18"
  local nmaj
  nmaj=$(node -p "process.versions.node.split('.')[0]")
  [[ "$nmaj" -lt 18 ]] && die "Node 版本太低 ($nmaj),需要 ≥ 18"

  # 定位源:优先同目录(自包含发行),其次仓库根(开发模式)
  local SCRIPT_DIR REPO_DIR SRC_MODE
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  if [[ -f "$SCRIPT_DIR/intercept.cjs" ]]; then
    REPO_DIR="$SCRIPT_DIR"
    SRC_MODE="自包含(同目录)"
  elif [[ -f "$SCRIPT_DIR/../../intercept.cjs" ]]; then
    REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
    SRC_MODE="仓库根"
  else
    die "找不到 intercept.cjs;既不在 $SCRIPT_DIR 也不在 $SCRIPT_DIR/../.."
  fi

  if [[ "$LOADER" == "esm" && ! -f "$REPO_DIR/intercept.mjs" ]]; then
    log "${WARN} 没找到 intercept.mjs,回退到 CJS"
    LOADER="cjs"
  fi

  log "=========================================="
  log " node_helper V3.2 · install"
  log "=========================================="
  log "  模式:    $MODE"
  log "  加载器:  $LOADER"
  log "  源位置:  $SRC_MODE  ($REPO_DIR)"
  log "  安装到:  $PREFIX"
  [[ "$MODE" == "wrapper" ]] && log "  wrapper: $WRAPPER"
  log ""

  mkdir -p "$PREFIX"
  cp -v "$REPO_DIR/intercept.cjs" "$PREFIX/"
  [[ -f "$REPO_DIR/intercept.mjs" ]] && cp -v "$REPO_DIR/intercept.mjs" "$PREFIX/"
  [[ -f "$REPO_DIR/package.json" ]]  && cp -v "$REPO_DIR/package.json"  "$PREFIX/"
  [[ -f "$REPO_DIR/.env.example" ]]  && cp -v "$REPO_DIR/.env.example"  "$PREFIX/"
  [[ -d "$REPO_DIR/prompts" ]]       && cp -rv "$REPO_DIR/prompts"      "$PREFIX/"

  if [[ -f "$REPO_DIR/.env" && ! -f "$PREFIX/.env" ]]; then
    cp -v "$REPO_DIR/.env" "$PREFIX/.env"
  elif [[ ! -f "$PREFIX/.env" && -f "$PREFIX/.env.example" ]]; then
    cp "$PREFIX/.env.example" "$PREFIX/.env"
    log "  ${OK} 已从 .env.example 生成 $PREFIX/.env"
  fi

  local FLAG
  if [[ "$LOADER" == "esm" ]]; then
    FLAG="--import=file://$PREFIX/intercept.mjs"
  else
    FLAG="--require=$PREFIX/intercept.cjs"
  fi

  case "$MODE" in
  wrapper)
    mkdir -p "$BIN_DIR"
    cat > "$WRAPPER" << WRAPEOF
#!/usr/bin/env bash
# node_helper V3.2 wrapper — 临时禁用:CLAUDE_INTERCEPT=off claude ...
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
      log "${WARN} $BIN_DIR 不在 PATH,请把这行加到 ~/.bashrc 或 ~/.zshrc:"
      log "       export PATH=\"$BIN_DIR:\$PATH\""
    fi
    ;;

  global)
    [[ -f "$PROFILE" ]] && sed -i.bak.$(date +%s) "/$MARK_BEGIN/,/$MARK_END/d" "$PROFILE"
    {
      echo ""
      echo "$MARK_BEGIN"
      echo "# 自动加载 intercept,靠 intercept.cjs 内部 gate 只在 Claude 进程激活"
      echo "export NODE_OPTIONS=\"$FLAG \${NODE_OPTIONS:-}\""
      echo "$MARK_END"
    } >> "$PROFILE"
    log ""
    log "${OK} 已写入 $PROFILE(下次登录 / source ~/.profile 生效)"
    ;;
  esac

  log ""
  log "完成。"
  log "  自测: CLAUDE_INTERCEPT_DEBUG=1 claude --version"
  log "  状态: bash $0 status"
  log "  卸载: bash $0 uninstall"
}

# ============================================================
#  cmd_status
# ============================================================
cmd_status() {
  log ""
  log "====== node_helper V3.2 · 状态 ======"
  log ""

  # [1] 安装目录
  log "[1] 安装目录"
  if [[ -d "$PREFIX" ]]; then
    log "    $OK $PREFIX"
    for f in intercept.cjs intercept.mjs package.json .env; do
      [[ -e "$PREFIX/$f" ]] && log "      $OK $f" || log "      $BAD $f 缺失"
    done
    [[ -d "$PREFIX/prompts" ]] \
      && log "      $OK prompts/ ($(ls "$PREFIX/prompts" 2>/dev/null | wc -l) 个文件)" \
      || log "      $WARN prompts/ 缺失"
  else
    log "    $BAD $PREFIX 不存在"
  fi

  # [2] wrapper
  log ""
  log "[2] wrapper 模式"
  if [[ -f "$WRAPPER" ]]; then
    if grep -q "node_helper" "$WRAPPER" 2>/dev/null; then
      log "    $OK $WRAPPER (是 node_helper)"
      local opt
      opt=$(grep -oE 'NODE_OPTIONS="[^"]+"' "$WRAPPER" | head -1 | sed 's/NODE_OPTIONS="//;s/"$//')
      log "      ${DIM}注入: $opt${RST}"
    else
      log "    $WARN $WRAPPER 存在但不是我们的"
    fi
  else
    log "    ${DIM}(未装 wrapper)${RST}"
  fi

  # [3] global
  log ""
  log "[3] 全局模式(~/.profile)"
  if grep -q "$MARK_BEGIN" "$PROFILE" 2>/dev/null; then
    log "    $OK $PROFILE 已注入"
    sed -n "/$MARK_BEGIN/,/$MARK_END/p" "$PROFILE" | sed 's/^/      /'
  else
    log "    ${DIM}(未注入)${RST}"
  fi

  # [4] PATH 解析
  log ""
  log "[4] PATH"
  local wc
  wc=$(command -v claude 2>/dev/null || echo "")
  if [[ -n "$wc" ]]; then
    log "    which claude → $wc"
    if [[ -f "$WRAPPER" ]]; then
      local a b
      a=$(realpath "$wc" 2>/dev/null || echo "$wc")
      b=$(realpath "$WRAPPER" 2>/dev/null || echo "$WRAPPER")
      [[ "$a" == "$b" ]] && log "      $OK 是 node_helper 包装器" \
                        || log "      $WARN 不是包装器(包装器可能不在 PATH 最前)"
    fi
    mapfile -t ALL < <(which -a claude 2>/dev/null || type -a -p claude 2>/dev/null)
    if [[ ${#ALL[@]} -gt 1 ]]; then
      log "    PATH 上共 ${#ALL[@]} 个 claude:"
      for p in "${ALL[@]}"; do log "      - $p"; done
    fi
  else
    log "    $BAD PATH 上找不到 claude"
  fi

  # [5] 当前 shell NODE_OPTIONS
  log ""
  log "[5] 当前 shell NODE_OPTIONS"
  if [[ -n "${NODE_OPTIONS:-}" ]]; then
    log "    $OK $NODE_OPTIONS"
  else
    log "    ${DIM}(未设置 — wrapper 模式下属正常)${RST}"
  fi

  # [6] 门禁自测
  log ""
  log "[6] 门禁自测"
  local ICJS=""
  [[ -f "$PREFIX/intercept.cjs" ]] && ICJS="$PREFIX/intercept.cjs"
  if [[ -n "$ICJS" ]]; then
    local out
    out=$(CLAUDE_INTERCEPT_DEBUG=1 node --require="$ICJS" \
          -e "console.log('loaded='+!!globalThis.__NODE_HELPER_V3_LOADED__)" 2>&1 || true)
    if echo "$out" | grep -q "skip"; then
      log "    $OK 非 Claude 进程被跳过(gate 工作)"
      echo "$out" | grep -E "ic v3|skip" | head -1 | sed 's/^/      /'
    elif echo "$out" | grep -q "active"; then
      log "    $WARN 被激活了 — 是否设了 CLAUDE_INTERCEPT_FORCE=1?"
    else
      log "    $WARN 未知:"; echo "$out" | head -3 | sed 's/^/      /'
    fi
  else
    log "    ${DIM}跳过(没找到 intercept.cjs)${RST}"
  fi

  # [7] 伴随服务
  log ""
  log "[7] 伴随服务(viewer 8787 / addon 8799)"
  local ports=""
  if command -v ss >/dev/null 2>&1; then
    ports=$(ss -lntp 2>/dev/null | grep -E ':(8787|8799) ' || true)
  else
    ports=$(netstat -lntp 2>/dev/null | grep -E ':(8787|8799) ' || true)
  fi
  if [[ -n "$ports" ]]; then
    echo "$ports" | sed 's/^/    /'
  else
    log "    ${DIM}(都没监听,intercept 会降级到 LOG_FILE)${RST}"
  fi
  log ""
}

# ============================================================
#  cmd_uninstall
# ============================================================
cmd_uninstall() {
  ASSUME_YES=0
  for a in "$@"; do
    case "$a" in -y|--yes) ASSUME_YES=1;; esac
  done

  log "====== node_helper V3.2 · 卸载 ======"
  log ""

  # 1. wrapper
  if [[ -f "$WRAPPER" ]] && grep -q "node_helper" "$WRAPPER" 2>/dev/null; then
    if confirm "删除 wrapper $WRAPPER?"; then
      rm -f "$WRAPPER"
      log "  $OK 已删 $WRAPPER"
    else
      log "  skip  保留 $WRAPPER"
    fi
  elif [[ -f "$WRAPPER" ]]; then
    log "  skip  $WRAPPER 不是我们的"
  else
    log "  skip  没 wrapper"
  fi

  # 2. ~/.profile
  if grep -q "$MARK_BEGIN" "$PROFILE" 2>/dev/null; then
    if confirm "从 $PROFILE 移除 NODE_OPTIONS 注入?"; then
      cp "$PROFILE" "$PROFILE.bak.$(date +%Y%m%d-%H%M%S)"
      sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$PROFILE"
      log "  $OK 已从 $PROFILE 移除(备份 .bak.xxx)"
      log "       本 shell 要重开或 'unset NODE_OPTIONS' 才立即生效"
    else
      log "  skip  保留 $PROFILE"
    fi
  else
    log "  skip  $PROFILE 没注入"
  fi

  # 3. 安装目录
  if [[ -d "$PREFIX" ]]; then
    log ""
    log "  $PREFIX 内容:"
    ls -la "$PREFIX" 2>/dev/null | sed 's/^/    /'
    [[ -f "$PREFIX/.env" ]] && log "  $WARN .env 可能含你的自定义规则 / token"
    if confirm "删除 $PREFIX?"; then
      rm -rf "$PREFIX"
      log "  $OK 已删 $PREFIX"
    else
      log "  skip  保留 $PREFIX"
    fi
  else
    log "  skip  $PREFIX 已不存在"
  fi

  # 4. 日志
  local logs=()
  for f in /tmp/node-helper-intercept.jsonl "$HOME/.cache/node-helper-intercept.jsonl"; do
    [[ -f "$f" ]] && logs+=("$f")
  done
  if [[ ${#logs[@]} -gt 0 ]]; then
    log ""
    log "  发现日志:"
    for f in "${logs[@]}"; do log "    - $f ($(du -h "$f" 2>/dev/null | cut -f1))"; done
    if confirm "删除日志?"; then
      for f in "${logs[@]}"; do rm -f "$f"; done
      log "  $OK 已清"
    fi
  fi

  log ""
  log "卸载完成。which claude 现在指向:"
  which claude 2>/dev/null | sed 's/^/  /' || log "  (PATH 上没 claude 了)"
}

# ============================================================
#  分发
# ============================================================
main() {
  local cmd="${1:-install}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    install)           cmd_install "$@" ;;
    status|st)         cmd_status ;;
    uninstall|remove)  cmd_uninstall "$@" ;;
    help|-h|--help)    usage ;;
    *)                 log "未知子命令: $cmd"; usage; exit 2 ;;
  esac
}

main "$@"
