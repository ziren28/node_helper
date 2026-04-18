// ============================================================
// node_helper V3.2 · intercept.mjs (ESM 入口)
//
// 通过 NODE_OPTIONS=--import=file:///...intercept.mjs 挂载。
//
// 本文件只做一件事:通过 createRequire 触发 intercept.cjs,
// 所有 hook / 改写逻辑仍然在 CJS 单文件里。这样维护一份代码、
// 两种挂载方式都能工作(CJS 走 --require,ESM 走 --import)。
//
// 为什么不直接 ESM 写 hook:
//   1. 所有 monkey-patch 都是给 CommonJS 模块打补丁(https、http 等
//      在 ESM 下也是同一个对象,但钩子代码本身 CJS 写起来更直白)
//   2. 复用既有 806 行的成熟实现,减少分叉
//   3. .cjs 里用了 require / module.exports / 顶层 return,ESM 不支持
//
// 为什么必须要有 package.json:
//   .mjs 扩展名本身是 ESM 无条件识别,但如果用户把本文件改名成 .js,
//   没 package.json 会被当 CommonJS 解析导致 import 语法报错。
//   为了稳健,同目录放一份 package.json,"type":"module"。
// ============================================================

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const require = createRequire(import.meta.url);

// 加载 CJS 入口;一切副作用(env 解析、hook 注册、banner)在这一步发生
require(resolve(__dirname, 'intercept.cjs'));
