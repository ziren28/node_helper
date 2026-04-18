// ============================================================
// node_helper V3.2 · intercept.cjs
// 单文件拦截 + 改写;配置读 .env;依赖:仅 Node 标准库
//
// 用法(CJS,旧路径,仍然支持):
//   set NODE_OPTIONS=--require=C:\Users\admin\node_helper\v3\intercept.cjs
//   claude
//
// 用法(ESM,推荐新版):
//   set NODE_OPTIONS=--import=file:///C:/Users/admin/node_helper/v3/intercept.mjs
//   claude
//
// 两种同时挂也安全(见顶部双加载防御)。
// ============================================================
'use strict';

// 双加载防御:同时挂 --require=.cjs 和 --import=.mjs(.mjs 内部 require .cjs)
// 会进来两次,只装一次 hook,避免双 wrap https.request 导致递归
if (globalThis.__NODE_HELPER_V3_LOADED__) {
  module.exports = {};
  return;
}
globalThis.__NODE_HELPER_V3_LOADED__ = true;

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const http = require('node:http');
const zlib = require('node:zlib');

const SELF_DIR = __dirname;

// ============================================================
// 入口门禁:只在 Claude 进程里激活,其它 Node 进程 0 影响
// (目的:允许 setx NODE_OPTIONS 全局注入而不污染 VS Code / npm 等)
// ============================================================
function shouldActivate() {
  try {
    // 手动强制关(调试用)
    if (process.env.CLAUDE_INTERCEPT_NEVER === '1') return { ok: false, reason: 'CLAUDE_INTERCEPT_NEVER=1' };
    // 手动强制开(调试用)
    if (process.env.CLAUDE_INTERCEPT_FORCE === '1') return { ok: true, reason: 'CLAUDE_INTERCEPT_FORCE=1' };

    // 白名单 env 变量(Claude Code 标志)
    const ENV_SIGNALS = [
      'CLAUDECODE',
      'CLAUDE_CODE_ENTRYPOINT',
      'CLAUDE_AGENT_SDK_VERSION',
      'CLAUDE_CODE_EXECPATH',
      'CLAUDE_CODE_OAUTH_TOKEN',
    ];
    for (const k of ENV_SIGNALS) {
      if (process.env[k]) return { ok: true, reason: `env:${k}` };
    }

    // 主入口 / argv 包含 "claude"
    const argv1 = (process.argv[1] || '').toLowerCase();
    if (argv1.includes('claude')) return { ok: true, reason: `argv:${argv1}` };

    const mainFile = (require.main && require.main.filename || '').toLowerCase();
    if (mainFile.includes('claude-code') || mainFile.includes('@anthropic-ai')) {
      return { ok: true, reason: `main:${path.basename(mainFile)}` };
    }

    return { ok: false, reason: 'no-signal' };
  } catch (e) {
    // 出错 = 不激活(安全默认)
    return { ok: false, reason: `error:${e.message}` };
  }
}

const GATE = shouldActivate();
if (!GATE.ok) {
  // 调试:想看被跳过的 Node 进程是谁,设 CLAUDE_INTERCEPT_DEBUG=1
  if (process.env.CLAUDE_INTERCEPT_DEBUG === '1') {
    process.stderr.write(`[ic v3] skip: ${GATE.reason} (argv=${JSON.stringify(process.argv)})\n`);
  }
  // 整个模块 return,下面所有 hook 代码都不执行
  module.exports = {};
  return;
}

// ---------------- .env 解析(不依赖 dotenv 包) ----------------
function loadEnv(envPath) {
  const out = {};
  if (!fs.existsSync(envPath)) return out;
  const text = fs.readFileSync(envPath, 'utf8');
  for (let line of text.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    // 支持 %VAR% 展开(Windows 风格)和 ${VAR}(Unix 风格)
    v = v.replace(/%([A-Za-z_][A-Za-z0-9_]*)%/g, (_, name) => process.env[name] || '');
    v = v.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => process.env[name] || '');
    out[k] = v;
  }
  return out;
}

const CFG = loadEnv(path.join(SELF_DIR, '.env'));

const cfgBool = (k, dflt = false) => {
  const v = (CFG[k] || '').toLowerCase().trim();
  if (['true', '1', 'yes', 'on'].includes(v)) return true;
  if (['false', '0', 'no', 'off'].includes(v)) return false;
  return dflt;
};
const cfgInt = (k) => {
  const v = (CFG[k] || '').trim();
  if (!v) return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
};
const cfgStr = (k) => ((CFG[k] || '').trim() || null);
const cfgList = (k) => {
  const v = (CFG[k] || '').trim();
  if (!v) return null;
  return v.split(',').map(s => s.trim()).filter(Boolean);
};
const readFileOrNull = (p) => {
  if (!p) return null;
  const abs = path.isAbsolute(p) ? p : path.join(SELF_DIR, p);
  try { return fs.readFileSync(abs, 'utf8'); } catch { return null; }
};

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// ---------------- 运行时规则(启动时编译一次) ----------------
const ENABLED = cfgBool('CLAUDE_INTERCEPT', true) && process.env.CLAUDE_INTERCEPT !== 'off';
const TARGET_HOST_SUFFIX = cfgStr('TARGET_HOST_SUFFIX') || 'anthropic.com';
const TARGET_RE = new RegExp(escapeRegex(TARGET_HOST_SUFFIX) + '$', 'i');

const LOG_MODE = (cfgStr('LOG_MODE') || 'off').toLowerCase();
const LOG_FILE = cfgStr('LOG_FILE');
const LOG_MASK_AUTH = cfgBool('LOG_MASK_AUTH', true);
const VIEWER_URL = cfgStr('VIEWER_URL') || 'http://127.0.0.1:8787/log';

// 解析 <system-reminder> 清理的匹配规则文件
function parseStripRules(text) {
  if (!text) return [];
  const rules = [];
  for (let line of text.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('re:')) {
      try { rules.push(new RegExp(line.slice(3), 'i')); } catch (e) {
        process.stderr.write(`[ic v3] 规则文件里正则错误,跳过: ${line} (${e.message})\n`);
      }
    } else {
      rules.push(line);  // 子串,后面匹配时做小写对比
    }
  }
  return rules;
}

const RULES = {
  authReplace:       cfgStr('HEADER_AUTH_REPLACE'),
  betaReplace:       cfgList('HEADER_BETA_REPLACE'),
  betaDrop:          cfgList('HEADER_BETA_DROP'),
  stripRemindersMode:   (cfgStr('STRIP_REMINDERS_MODE') || 'off').toLowerCase(),
  stripRemindersRules:  parseStripRules(readFileOrNull(cfgStr('STRIP_REMINDERS_MATCHES_FILE'))),
  maxTokensCap:      cfgInt('MAX_TOKENS_CAP'),
  maxTokensForce:    cfgInt('MAX_TOKENS_FORCE'),
  budgetCap:         cfgInt('BUDGET_CAP'),
  budgetForce:       cfgInt('BUDGET_FORCE'),
  disableThinking:   cfgBool('DISABLE_THINKING', false),
  fakeDeviceId:      cfgStr('FAKE_DEVICE_ID'),
  fakeAccountUuid:   cfgStr('FAKE_ACCOUNT_UUID'),
  fakeSessionId:     cfgStr('FAKE_SESSION_ID'),
  stripMetadata:     cfgBool('STRIP_METADATA', false),
  systemReplaceText: readFileOrNull(cfgStr('SYSTEM_REPLACE_FILE')),       // # System 段
  systemFullReplace: readFileOrNull(cfgStr('SYSTEM_FULL_REPLACE_FILE')),  // 整个 system[2]
  systemPrefixText:  readFileOrNull(cfgStr('SYSTEM_PREFIX_FILE')),
  systemSuffixText:  readFileOrNull(cfgStr('SYSTEM_SUFFIX_FILE')),
  // 通用正则/子串替换(系统 prompt 层面,细粒度;在 # System 段替换之前执行)
  systemPatterns:    parseSystemPatternRules(readFileOrNull(cfgStr('SYSTEM_PATTERNS_FILE'))),
};

// ---------------- <system-reminder> 清理 ----------------
// 匹配一个完整 reminder 块
const REMINDER_BLOCK_RE = /<system-reminder>[\s\S]*?<\/system-reminder>\s*/g;

function reminderMatchesRules(block, rules) {
  const lower = block.toLowerCase();
  for (const r of rules) {
    if (r instanceof RegExp) {
      if (r.test(block)) return true;
    } else {
      if (lower.includes(r.toLowerCase())) return true;
    }
  }
  return false;
}

// ---------------- system[2] 文本正则/子串替换 ----------------
/**
 * 规则文件格式(每行一条):
 *   pattern                → 匹配到的内容被删除
 *   pattern => replacement → 匹配到的内容被替换成 replacement
 *
 * pattern 语法:
 *   默认           不分大小写的子串匹配(全局替换所有出现)
 *   're:' 前缀      正则(自动加 gi 标记)
 */
function parseSystemPatternRules(text) {
  if (!text) return [];
  const rules = [];
  for (let raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const sep = line.indexOf(' => ');
    const pattern = sep >= 0 ? line.slice(0, sep) : line;
    const repl = sep >= 0 ? line.slice(sep + 4) : '';
    if (pattern.startsWith('re:')) {
      try {
        // gim: g=全局 i=不分大小写 m=^ $ 匹配行首行尾(删 IMPORTANT 这类多行要用)
        rules.push({ re: new RegExp(pattern.slice(3), 'gim'), repl, kind: 'regex' });
      } catch (e) {
        process.stderr.write(`[ic v3] system pattern 正则错误,跳过: ${pattern} (${e.message})\n`);
      }
    } else if (pattern) {
      rules.push({
        re: new RegExp(escapeRegex(pattern), 'gi'),
        repl, kind: 'substring', raw: pattern
      });
    }
  }
  return rules;
}

function applySystemPatterns(text, rules) {
  if (!rules || !rules.length) return { text, hits: 0 };
  let hits = 0;
  for (const r of rules) {
    const nt = text.replace(r.re, r.repl);
    if (nt !== text) { text = nt; hits++; }
  }
  // 收尾:压缩由删除造成的多余空行(3 行及以上 → 2 行)
  text = text.replace(/\n{3,}/g, '\n\n');
  return { text, hits };
}

// 对单段文本执行剥离;返回新文本
function stripRemindersInText(text, mode, rules) {
  if (mode === 'all') {
    return text.replace(REMINDER_BLOCK_RE, '');
  }
  if (mode === 'matched') {
    return text.replace(REMINDER_BLOCK_RE, (m) => reminderMatchesRules(m, rules) ? '' : m);
  }
  return text;
}

/**
 * 在 JSON payload 层清理 reminder:
 *   - 单个 content block 的 text 被清空 → 丢掉整个 block
 *   - 一个 message 的 content 数组全空 → 丢掉整个 message
 * 这样不会留 empty text block / empty messages 触发 API 400。
 */
function stripRemindersFromPayload(payload, mode, rules) {
  if (mode === 'off' || !Array.isArray(payload.messages)) return 0;
  if (mode === 'matched' && (!rules || !rules.length)) return 0;
  let hits = 0;
  const keptMessages = [];

  for (const msg of payload.messages) {
    let keepMessage = true;

    if (typeof msg.content === 'string') {
      const newText = stripRemindersInText(msg.content, mode, rules);
      if (newText !== msg.content) { hits++; msg.content = newText; }
      // 字符串 content 为空也保留(用户可能发空消息;Anthropic 有它的判定)
    } else if (Array.isArray(msg.content)) {
      const keptBlocks = [];
      for (const block of msg.content) {
        if (block && block.type === 'text' && typeof block.text === 'string') {
          const newText = stripRemindersInText(block.text, mode, rules);
          if (newText !== block.text) {
            hits++;
            if (newText.trim()) {
              keptBlocks.push({ ...block, text: newText });
            }
            // newText 纯空白 → 丢掉整个 block
          } else {
            keptBlocks.push(block);
          }
        } else {
          keptBlocks.push(block);  // 非 text block(image / tool_use / ...)原样保留
        }
      }
      if (keptBlocks.length !== msg.content.length) {
        msg.content = keptBlocks;
      }
      if (keptBlocks.length === 0) keepMessage = false;
    }

    if (keepMessage) keptMessages.push(msg);
  }

  if (keptMessages.length !== payload.messages.length) {
    payload.messages = keptMessages;
  }
  return hits;
}

// ---------------- system[2] 按段替换 ----------------
function findMainSystemBlock(sysList) {
  if (!Array.isArray(sysList)) return [-1, null];
  for (let i = 0; i < sysList.length; i++) {
    const b = sysList[i];
    if (b && typeof b === 'object' && b.cache_control && b.type === 'text') return [i, b];
  }
  let best = -1, bestLen = -1;
  for (let i = 0; i < sysList.length; i++) {
    const b = sysList[i];
    if (b && b.type === 'text') {
      const n = (b.text || '').length;
      if (n > bestLen) { best = i; bestLen = n; }
    }
  }
  return best >= 0 ? [best, sysList[best]] : [-1, null];
}

/**
 * 替换 system[2] 文本里的 "# <sectionName>" 段:
 * 从 "# sectionName" 开始,到下一个 "# " 前结束。
 * 其它段(含引言、IMPORTANT、后续各段)全部保留。
 *
 * newBody 可以包含 "# sectionName" 开头,也可以省略(会自动补上)。
 */
function replaceSectionByHeader(text, sectionName, newBody) {
  const parts = text.split(/\n(?=# \S)/);  // 按顶级 "# X" 切,不消耗分隔符
  let replacedIdx = -1;
  for (let i = 0; i < parts.length; i++) {
    const firstLine = parts[i].split('\n', 1)[0];
    if (new RegExp(`^# ${escapeRegex(sectionName)}\\b`).test(firstLine)) {
      replacedIdx = i;
      break;
    }
  }
  if (replacedIdx < 0) {
    // 原文里没有这一段,直接追加到末尾
    let appended = newBody.replace(/\s+$/, '');
    if (!new RegExp(`^# ${escapeRegex(sectionName)}\\b`).test(appended)) {
      appended = `# ${sectionName}\n` + appended;
    }
    return text.replace(/\s*$/, '') + '\n\n' + appended + '\n';
  }
  let rep = newBody.replace(/\s+$/, '');
  if (!new RegExp(`^# ${escapeRegex(sectionName)}\\b`).test(rep)) {
    rep = `# ${sectionName}\n` + rep;
  }
  parts[replacedIdx] = rep;
  return parts.join('\n');
}

// ---------------- JSON 层改写 ----------------
function applyJsonRules(payload) {
  const changes = [];

  // system[2]
  const sysList = payload.system;
  if (Array.isArray(sysList)) {
    const [idx, block] = findMainSystemBlock(sysList);
    if (block) {
      let text = block.text || '';
      if (RULES.systemFullReplace) {
        if (text !== RULES.systemFullReplace) {
          block.text = RULES.systemFullReplace;
          changes.push('system-full-replaced');
        }
      } else {
        // [0] 通用正则/子串替换(IMPORTANT 红线、任意句子 patch 等)
        if (RULES.systemPatterns && RULES.systemPatterns.length) {
          const { text: nt, hits } = applySystemPatterns(text, RULES.systemPatterns);
          if (nt !== text) {
            text = nt;
            changes.push(`system-patterns-${hits}`);
          }
        }
        // [1] 替换 # System 段
        if (RULES.systemReplaceText) {
          const newText = replaceSectionByHeader(text, 'System', RULES.systemReplaceText);
          if (newText !== text) {
            text = newText;
            changes.push('system-section:System-replaced');
          }
        }
        // [2] 前置 / 后置
        if (RULES.systemPrefixText) {
          text = RULES.systemPrefixText + (text.startsWith('\n') ? '' : '\n') + text;
          changes.push('system-prefix');
        }
        if (RULES.systemSuffixText) {
          text = text.replace(/\s*$/, '') + '\n\n' + RULES.systemSuffixText;
          changes.push('system-suffix');
        }
        if (text !== block.text) block.text = text;
      }
    }
  } else if (typeof sysList === 'string' && RULES.systemFullReplace) {
    payload.system = RULES.systemFullReplace;
    changes.push('system-full-replaced');
  }

  // metadata
  if (RULES.stripMetadata && 'metadata' in payload) {
    delete payload.metadata;
    changes.push('metadata-stripped');
  } else if (payload.metadata && typeof payload.metadata === 'object') {
    const uidRaw = payload.metadata.user_id;
    if (typeof uidRaw === 'string') {
      let uid;
      try { uid = JSON.parse(uidRaw); } catch { uid = null; }
      if (uid && typeof uid === 'object') {
        let changed = false;
        if (RULES.fakeDeviceId && uid.device_id !== RULES.fakeDeviceId) {
          uid.device_id = RULES.fakeDeviceId; changed = true;
        }
        if (RULES.fakeAccountUuid && uid.account_uuid !== RULES.fakeAccountUuid) {
          uid.account_uuid = RULES.fakeAccountUuid; changed = true;
        }
        if (RULES.fakeSessionId && uid.session_id !== RULES.fakeSessionId) {
          uid.session_id = RULES.fakeSessionId; changed = true;
        }
        if (changed) {
          payload.metadata.user_id = JSON.stringify(uid);
          changes.push('metadata-user_id-faked');
        }
      }
    }
  }

  // max_tokens
  if (RULES.maxTokensForce != null && payload.max_tokens !== RULES.maxTokensForce) {
    payload.max_tokens = RULES.maxTokensForce;
    changes.push(`max_tokens=${RULES.maxTokensForce}`);
  } else if (RULES.maxTokensCap != null &&
             typeof payload.max_tokens === 'number' &&
             payload.max_tokens > RULES.maxTokensCap) {
    const old = payload.max_tokens;
    payload.max_tokens = RULES.maxTokensCap;
    changes.push(`max_tokens=${old}->${RULES.maxTokensCap}`);
  }

  // thinking
  if (RULES.disableThinking && 'thinking' in payload) {
    delete payload.thinking;
    changes.push('thinking-disabled');
  } else if (payload.thinking && typeof payload.thinking === 'object' && 'budget_tokens' in payload.thinking) {
    if (RULES.budgetForce != null && payload.thinking.budget_tokens !== RULES.budgetForce) {
      payload.thinking.budget_tokens = RULES.budgetForce;
      changes.push(`budget=${RULES.budgetForce}`);
    } else if (RULES.budgetCap != null && payload.thinking.budget_tokens > RULES.budgetCap) {
      const old = payload.thinking.budget_tokens;
      payload.thinking.budget_tokens = RULES.budgetCap;
      changes.push(`budget=${old}->${RULES.budgetCap}`);
    }
  }

  return changes;
}

// ---------------- 应用所有规则(headers + body) ----------------
function applyRules(ctx) {
  const changes = [];

  // headers: authorization
  if (RULES.authReplace) {
    const key = Object.keys(ctx.headers).find(k => k.toLowerCase() === 'authorization') || 'authorization';
    if (ctx.headers[key] !== RULES.authReplace) {
      ctx.headers[key] = RULES.authReplace;
      changes.push('auth-replaced');
    }
  }

  // headers: anthropic-beta
  if (RULES.betaReplace || RULES.betaDrop) {
    const key = Object.keys(ctx.headers).find(k => k.toLowerCase() === 'anthropic-beta') || 'anthropic-beta';
    const orig = ctx.headers[key] || '';
    let flags = orig.split(',').map(s => s.trim()).filter(Boolean);
    if (RULES.betaReplace) flags = [...RULES.betaReplace];
    if (RULES.betaDrop) flags = flags.filter(f => !RULES.betaDrop.some(d => f.includes(d)));
    const joined = flags.join(',');
    if (joined !== orig) {
      if (joined) ctx.headers[key] = joined;
      else delete ctx.headers[key];
      changes.push('beta-changed');
    }
  }

  // body: JSON 层统一处理(strip reminders + 其它 JSON 规则)
  if (typeof ctx.body === 'string' && ctx.body.startsWith('{')) {
    let payload;
    try { payload = JSON.parse(ctx.body); } catch {}
    if (payload && typeof payload === 'object') {
      // 1) 剥 reminder(按 block 粒度;空 block / 空 message 自动丢弃)
      if (RULES.stripRemindersMode !== 'off') {
        const hits = stripRemindersFromPayload(payload, RULES.stripRemindersMode, RULES.stripRemindersRules);
        if (hits > 0) changes.push(`reminders-${RULES.stripRemindersMode}-${hits}`);
      }
      // 2) 其它 JSON 规则(system / metadata / max_tokens / thinking)
      const jc = applyJsonRules(payload);
      if (jc.length) changes.push(...jc);
      // 任一变动就回写
      if (changes.some(c => c.startsWith('reminders-')) || jc.length) {
        ctx.body = JSON.stringify(payload);
      }
    }
  }

  return changes;
}

// ---------------- 日志 ----------------
let LOG_FD = null;
function getLogFd() {
  if (LOG_MODE !== 'file' || !LOG_FILE) return null;
  if (LOG_FD === null) {
    try { LOG_FD = fs.openSync(LOG_FILE, 'a'); }
    catch (e) { process.stderr.write(`[ic v3] open log failed: ${e.message}\n`); LOG_FD = -1; }
  }
  return LOG_FD > 0 ? LOG_FD : null;
}

function maskHeaders(h) {
  if (!LOG_MASK_AUTH) return h;
  const out = {};
  for (const k of Object.keys(h || {})) {
    const v = h[k];
    if (/authorization|cookie|x-api-key/i.test(k)) {
      const s = String(v || '');
      out[k] = s.length > 24 ? s.slice(0, 14) + '…' + s.slice(-6) : '<masked>';
    } else {
      out[k] = v;
    }
  }
  return out;
}

function sendToViewer(entry) {
  try {
    const body = Buffer.from(JSON.stringify(entry));
    const u = new URL(VIEWER_URL);
    const req = http.request({
      host: u.hostname, port: Number(u.port) || 80, path: u.pathname || '/', method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': body.length, 'x-internal-log': '1' },
    });
    req.on('error', () => {});
    req.end(body);
  } catch {}
}

function logEntry(entry) {
  const fd = getLogFd();
  if (fd) {
    try { fs.writeSync(fd, JSON.stringify(entry) + '\n'); } catch {}
  }
  if (LOG_MODE === 'stderr') {
    const ch = (entry.changes || []).join(',') || '-';
    process.stderr.write(`[ic] ${entry.method} ${entry.url} → ${entry.resStatus || entry.error || '?'} · ${ch}\n`);
  }
  sendToViewer(entry);
}

// ---------------- 响应解压 ----------------
function sniffEncoding(buf) {
  if (!buf || buf.length < 2) return '';
  if (buf[0] === 0x1f && buf[1] === 0x8b) return 'gzip';
  if (buf.length >= 4 && buf[0] === 0x28 && buf[1] === 0xb5 && buf[2] === 0x2f && buf[3] === 0xfd) return 'zstd';
  if (buf[0] === 0x78 && (buf[1] === 0x01 || buf[1] === 0x9c || buf[1] === 0xda)) return 'deflate';
  return '';
}

function decodeResBody(raw, headers) {
  if (!raw || raw.length === 0) return '';
  const fromHeader = String((headers && (headers['content-encoding'] || headers['Content-Encoding'])) || '').toLowerCase().trim();
  const enc = fromHeader || sniffEncoding(raw);
  try {
    if (enc === 'gzip') raw = zlib.gunzipSync(raw);
    else if (enc === 'br') raw = zlib.brotliDecompressSync(raw);
    else if (enc === 'deflate') raw = zlib.inflateSync(raw);
    else if (enc === 'zstd' && zlib.zstdDecompressSync) raw = zlib.zstdDecompressSync(raw);
  } catch {}
  return raw.toString('utf8');
}

// ---------------- 请求 ID ----------------
let SEQ = 0;
const nextId = () => `${Date.now().toString(36)}-${(++SEQ).toString(36)}`;

// ---------------- 提取 https 参数 ----------------
function extractHttpsArgs(arg0, arg1) {
  let host = '', url = '', method = 'GET', headers = {};
  if (typeof arg0 === 'string' || arg0 instanceof URL) {
    url = String(arg0);
    try { host = new URL(url).hostname; } catch {}
    if (arg1 && typeof arg1 === 'object' && typeof arg1 !== 'function') {
      method = arg1.method || 'GET';
      headers = arg1.headers || {};
    }
  } else if (arg0 && typeof arg0 === 'object') {
    host = arg0.hostname || arg0.host || '';
    const p = arg0.path || '/';
    url = `${arg0.protocol || 'https:'}//${host}${arg0.port ? ':' + arg0.port : ''}${p}`;
    method = arg0.method || 'GET';
    headers = arg0.headers || {};
  }
  return { host, url, method, headers };
}

// ---------------- hook https.request ----------------
function hookHttps() {
  const orig = https.request;
  https.request = function patched(arg0, arg1, arg2) {
    const { host, url, method, headers: origHeaders } = extractHttpsArgs(arg0, arg1);
    if (!ENABLED || !host || !TARGET_RE.test(host)) {
      return orig.apply(this, arguments);
    }
    const userCb = typeof arg2 === 'function' ? arg2 : (typeof arg1 === 'function' ? arg1 : null);
    const id = nextId();
    const startedAt = Date.now();
    const reqChunks = [];
    const resChunks = [];
    let req;
    const headers = { ...origHeaders };

    const onResponse = (res) => {
      res.on('data', (c) => resChunks.push(Buffer.from(c)));
      res.on('end', () => {
        const rawBuf = Buffer.concat(resChunks);
        logEntry({
          id, startedAt, endedAt: Date.now(),
          url, method,
          reqHeaders: maskHeaders(req && req.__newHeaders || headers),
          reqBody: (req && req.__newBody) ?? Buffer.concat(reqChunks).toString('utf8'),
          origUrl: url,
          origReqHeaders: maskHeaders(origHeaders),
          origReqBody: req && req.__origBody,
          rewritten: !!(req && req.__changes && req.__changes.length),
          changes: (req && req.__changes) || [],
          resStatus: res.statusCode,
          resHeaders: res.headers,
          resBody: decodeResBody(rawBuf, res.headers),
          transport: 'https',
        });
      });
      res.on('error', () => {});
      if (userCb) userCb(res);
    };

    req = orig.apply(this, typeof arg0 === 'string' || arg0 instanceof URL
      ? (typeof arg1 === 'object' && arg1 !== null ? [arg0, arg1, onResponse] : [arg0, onResponse])
      : [arg0, onResponse]);

    const origWrite = req.write.bind(req);
    const origEnd = req.end.bind(req);
    let ended = false;

    req.write = (c, enc, cb) => {
      if (c) reqChunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c, typeof enc === 'string' ? enc : 'utf8'));
      if (typeof cb === 'function') setImmediate(cb);
      else if (typeof enc === 'function') setImmediate(enc);
      return true;
    };

    req.end = (c, enc, cb) => {
      if (ended) return req;
      ended = true;
      let cbFn;
      if (typeof c === 'function') { cbFn = c; c = undefined; }
      else if (typeof enc === 'function') { cbFn = enc; enc = undefined; }
      else cbFn = cb;
      if (c) reqChunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c, typeof enc === 'string' ? enc : 'utf8'));

      const origBody = Buffer.concat(reqChunks).toString('utf8');
      const ctx = { url, method, headers: { ...headers }, body: origBody };
      const changes = applyRules(ctx);

      // 同步 headers 到 req
      for (const k of Object.keys(headers)) {
        if (!(k in ctx.headers)) { try { req.removeHeader(k); } catch {} }
      }
      for (const [k, v] of Object.entries(ctx.headers)) {
        if (headers[k] !== v) { try { req.setHeader(k, v); } catch {} }
      }

      const finalBuf = Buffer.from(ctx.body || '', 'utf8');
      try { req.setHeader('content-length', finalBuf.length); } catch {}

      req.__origBody = origBody;
      req.__newBody = ctx.body;
      req.__newHeaders = ctx.headers;
      req.__changes = changes;

      origWrite(finalBuf);
      return origEnd(undefined, undefined, cbFn);
    };

    req.on('error', (err) => {
      logEntry({
        id, startedAt, endedAt: Date.now(),
        url, method,
        reqHeaders: maskHeaders(headers),
        origReqHeaders: maskHeaders(origHeaders),
        origUrl: url,
        rewritten: false, changes: [],
        error: String(err && err.message || err),
        transport: 'https',
      });
    });

    return req;
  };
}

// ---------------- hook global fetch ----------------
function hookFetch() {
  const origFetch = globalThis.fetch;
  if (typeof origFetch !== 'function') return;

  globalThis.fetch = async function patched(input, init = {}) {
    let origUrl = '';
    try { origUrl = typeof input === 'string' ? input : (input && input.url) || String(input); } catch {}
    let host = '';
    try { host = new URL(origUrl).hostname; } catch {}

    if (!ENABLED || !host || !TARGET_RE.test(host)) {
      return origFetch.call(this, input, init);
    }

    const id = nextId();
    const startedAt = Date.now();
    const method = (init.method || (typeof input !== 'string' && input && input.method) || 'GET').toUpperCase();
    const origHeaders = {};
    try {
      const h = init.headers || (typeof input !== 'string' && input && input.headers) || {};
      if (h && typeof h.forEach === 'function') h.forEach((v, k) => { origHeaders[k] = v; });
      else if (h && typeof h === 'object') Object.assign(origHeaders, h);
    } catch {}

    let origBody = '';
    try {
      if (init.body != null) origBody = typeof init.body === 'string' ? init.body : Buffer.from(init.body).toString('utf8');
    } catch {}

    const ctx = { url: origUrl, method, headers: { ...origHeaders }, body: origBody };
    const changes = applyRules(ctx);

    let newInput = input, newInit = init;
    if (changes.length > 0) {
      newInput = ctx.url;
      newInit = { ...init, method, headers: ctx.headers };
      if (origBody || ctx.body) newInit.body = ctx.body;
    }

    try {
      const res = await origFetch.call(this, newInput, newInit);
      const clone = res.clone();
      clone.text().then((text) => {
        logEntry({
          id, startedAt, endedAt: Date.now(),
          url: ctx.url, method,
          reqHeaders: maskHeaders(ctx.headers),
          reqBody: ctx.body,
          origUrl,
          origReqHeaders: maskHeaders(origHeaders),
          origReqBody: origBody,
          rewritten: changes.length > 0,
          changes,
          resStatus: res.status,
          resHeaders: Object.fromEntries(res.headers.entries()),
          resBody: text,
          transport: 'fetch',
        });
      }).catch(() => {});
      return res;
    } catch (err) {
      logEntry({
        id, startedAt, endedAt: Date.now(),
        url: ctx.url, method,
        reqHeaders: maskHeaders(ctx.headers),
        reqBody: ctx.body,
        origUrl,
        origReqHeaders: maskHeaders(origHeaders),
        origReqBody: origBody,
        rewritten: changes.length > 0,
        changes,
        error: String(err && err.message || err),
        transport: 'fetch',
      });
      throw err;
    }
  };
}

// ---------------- 启动 ----------------
if (ENABLED) {
  hookHttps();
  hookFetch();
  if (!globalThis.__INTERCEPT_V3_BANNER__) {
    globalThis.__INTERCEPT_V3_BANNER__ = true;
    const active = Object.entries(RULES)
      .filter(([, v]) => v !== null && v !== false && v !== '' && (!Array.isArray(v) || v.length))
      .map(([k]) => k);
    process.stderr.write(
      `[ic v3] active (${GATE.reason}) · target=${TARGET_HOST_SUFFIX} · log=${LOG_MODE}`
      + (LOG_MODE === 'file' ? ` (${LOG_FILE})` : '')
      + ` · rules=${active.length ? active.join(',') : 'none'}\n`
    );
  }
} else {
  process.stderr.write('[ic v3] disabled by CLAUDE_INTERCEPT=off\n');
}
