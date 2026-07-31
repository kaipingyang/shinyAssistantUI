# shinyAssistantUI — Developer Notes

## CRITICAL: 必须使用中文回复
所有回复必须使用中文，包括解释、分析、建议等。代码、命令、文件路径等技术内容保持原样。

Shiny htmlwidget wrapping `@assistant-ui/react`. R package + React/TypeScript frontend.

## ⚡ 最新状态（截至 2026-07-21）—— 先读这节，历史小节数字可能滞后

> 本文档后半是**逐批次 changelog**（保留作历史）。若与本节冲突，**以本节 + `package.json` + `tests/` 为准**。
> 操作流程与硬约束见 **[AGENTS.md](./AGENTS.md) Rule #0**（codegraph sync → 双图探索 → 写 plan → 自审5遍 → 测试先行 → 无头浏览器验证）。

**当前 UI 栈（重要）**：已从 `@assistant-ui/react-ui` 的预制 `Thread` 迁移到**本仓自建组件树**
`srcjs/components/assistant-ui/*`（`thread.tsx`、`composer-input.tsx` 基于 Lexical、`thread-list.tsx`、
`shiny-tool-fallback.tsx` 等）。`srcjs/AssistantUI.legacy.tsx` 是**死代码**，live 树**不 import 它**
（CI 硬约束：`srcjs` 内不得出现 legacy import）。

**关键依赖实际版本（以 package.json 为准）**：`@assistant-ui/react` 0.14.27、`react-lexical` 0.2.5、
`lexical` 0.47.0、`react`/`react-dom` 19.2.7、`react-markdown` ^0.14.5、`react-syntax-highlighter` ^0.14.2、
`radix-ui` ^1.6.1、`vite` ^5.4.21。构建为**单 IIFE**（`vite.config.mts` `lib.formats:["iife"]` +
`inlineDynamicImports:true`）→ **无法代码分割**，减体积只能靠 tree-shaking / 少 import 重物。

**测试规模**：JS `npx vitest run` = **9 文件 / 166 用例**；R `testthat` = 18 个 `test-*.R`（addin/context-usage/
session-archive/session-warmup/persistence/workspace-cache/handler-permissions/ide-context/skills/theme…）。
`tests/verify/` 有 40+ 真实 chromote 脚本（见下）。

**bundle 分析**：`npm run build` 产出 `inst/www/bundle-stats.html`（rollup-plugin-visualizer，gitignore）——
想评估体积先看它。曾用它当场抓出"误用 `@assistant-ui/react-syntax-highlighter` 工厂把 ~200 语言全内联使
bundle 翻倍"的回归；助手代码块高亮改用 `PrismLight` + 显式 `registerLanguage` 才回落。

**Claude addin 近期批次（均测试先行 + chromote 验证，见 `.claude/plans/08–11`）**：

| 能力 | R 接口 / 位置 | 前端 | 验证脚本 |
|---|---|---|---|
| 显式持久化 | `assistantUIServer(persistence=c("client","server","none"))`；addin 用 `server` | server/none 首帧不读写 localStorage | `verify_slash_context_history.R` |
| 历史分页 | `on_session_load(session_id,thread_id,send_thread,cursor,limit)` + LRU snapshot(≤3) | 初始最新50 + 向上加载/prepend去重 | `verify_slash_context_history.R` |
| 双阶段历史状态 | — | `Loading history…` / `Resuming Claude Code session…` | 同上 |
| Slash 菜单 + Tab | `commands`(skill,蓝chip) vs `action_items`(literal) | Tab 补全成 chip、Enter/点击执行；菜单高亮 scrollIntoView | 同上 |
| /context 精简 | `.format_context_usage` 仅摘要+分类表 | — | 同上（`test-context-usage.R`）|
| 工具卡默认折叠 | `toolHistoryDefaultOpen` | 历史大结果折叠、审批展开 | 同上 |
| 点击文件打开 | `assistantUIServer(on_open_file=)`；addin→`rstudioapi::navigateToFile` | 工具卡 `[data-open-file]` | `verify_openfile_reveal.R` |
| 编辑后揭示 | server `.new_edit_reveal_tracker` on_done flush | — | 同上（只揭示最近一次成功编辑）|
| 会话删除/归档(方案B) | `on_delete_session`(真删磁盘`delete_session`+确认) / `on_archive_session`(per-project rds 软隐藏,可恢复) | Delete→AlertDialog确认；归档区+Unarchive | `verify_delete_archive.R` |
| 助手代码块高亮 | — | `syntax-highlighter.tsx`(PrismLight+oneLight)接进 markdown | 同上 |
| 侧栏折叠 | — | `thread-sidebar.tsx`(折叠时消失、按钮移主面板)，localStorage 持久化(含 server 模式) | 同上 |
| workspace 索引 | `.addin_workspace_index_cached`(project+git HEAD 缓存, O(n²)→unique) | `@` 提及 | `verify_addin.R` |
| RStudio Viewer 输入框 | — | `composer-input.tsx` 挂载后写 inline 关键样式(Viewer 外部 CSS 失效兜底) | `verify_slash_context_history.R` |

**codegraph**：本仓与 `assistant-ui-src/`（上游源码 2600+ 文件）均已建索引，写码前 `codegraph query|explore|node`
双图查扩展点。`.codegraph/` 保持未跟踪。

---

## Architecture

```
R layer (htmlwidgets)          JS layer (React)
─────────────────────          ────────────────
assistantUIOutput()      →     HTMLWidgets.widget { name: "assistantUI" }
assistantUIServer()            useShinyRuntime(inputId)
  session$sendCustomMessage      ↔ Shiny.addCustomMessageHandler
  input[[input_id]]              ↔ Shiny.setInputValue
                                 AssistantRuntimeProvider
                                   └─ Thread (@assistant-ui/react-ui)
```

### Design decisions (why the code looks like this) — 2026-07-30

- **One integrated widget, not per-component Shiny UI.** Only `assistantUIOutput/Server/Page` are
  exposed (plus config/lifecycle helpers: `assistant_theme`, `make_claude_handler`,
  `assistant_tool_view`, `claude_addin`, session loaders/stores, `load_claude_skills`). The React
  UI primitives (button/dialog/thread/model-selector/tool-card…) are **internal** and deliberately
  NOT exposed as individual R components: the whole chat is one stateful React app (Zustand runtime)
  whose pieces share live state (streaming, thread list, approval queue, composer, usage). Decomposing
  them into R-level widgets would break that runtime, create a huge API surface bound to upstream
  internals, and force needless R↔JS round-trips. This mirrors **shinychat** (Posit), which likewise
  exposes one `chat_ui()` + module + server helpers (`chat_append/clear/…`) and keeps its Lit web
  components internal — the only standalone piece it factors out is `markdown_stream()` (streaming
  markdown outside a chat); we have no such need yet.
- **base-ui vs radix-ui.** `@base-ui/react` and `radix-ui` are two independent, competing headless
  libraries (base-ui uses floating-ui, not radix). Our vendored `@/components/ui/*` primitives are
  migrated to base-ui to match upstream `@assistant-ui/react` 0.15.1's `ui/` layer, and **no srcjs
  file imports `radix-ui`** anymore. `radix-ui` remains a *dependency* only because
  `@assistant-ui/react` (the npm package) still uses it internally for its own primitives
  (ActionBarMore / ThreadListItemMore / AssistantModal / Composer) — same as upstream 0.15.1.
- **Kept shadcn scaffold.** ~18 unused self-drawn `@/components/ui/*` files (card/table/alert/…) are
  kept as a component toolbox; they carry no radix (not old-version debt) and tree-shake out of the
  bundle. The 27 *radix-based* scaffold files that upstream 0.15.1 does not ship were trimmed. When a
  new control is needed, pull the base-ui version (shadcn base-ui registry / `@base-ui/react`) rather
  than restoring a radix copy.

### Key files

```
R/
  assistantUI.R       # assistantUIOutput() + renderAssistantUI()
  server.R            # assistantUIServer() — Shiny module, streaming logic
srcjs/
  index.tsx           # HTMLWidgets.widget registration
  AssistantUI.tsx     # Root React component (RuntimeProvider + Thread)
  runtime.ts          # useShinyRuntime() — ExternalStoreRuntime adapter
  bridge.ts           # createShinyBridge() — sendCustomMessage / setInputValue
inst/
  www/
    shinyAssistantUI.js   # compiled IIFE bundle (committed, pre-built)
    style.css             # compiled CSS (committed, pre-built)
  htmlwidgets/
    assistantUI.yaml      # htmlwidgets dependency declaration
```

### Communication protocol

| Direction | Mechanism | Message type |
|---|---|---|
| User → R | `Shiny.setInputValue(inputId, {text, attachments, ts})` | `input[[input_id]]` |
| R → React (stream) | `session$sendCustomMessage("ns:chunk", list(text=...))` | token append |
| R → React (done) | `session$sendCustomMessage("ns:done", list())` | finalize message |
| R → React (error) | `session$sendCustomMessage("ns:error", list(message=...))` | error display |

The `inputId` passed to the widget is `session$ns(paste0(id, "_input"))`, so multi-instance module isolation is automatic.

### JS dependencies

All npm deps are **local** to the project (not global). The compiled bundle is self-contained — no npm required by end users.

Key packages:
- `@assistant-ui/react` 0.14.7 — runtime + primitives（0.14.x 新增 `useToolArgsStatus`、`MessagePrimitive.Unstable_PartsGroupedByParentId`、ChainOfThought 原语、Voice session）
- `@assistant-ui/react-ui` 0.2.1 — pre-styled `Thread` component
- `@assistant-ui/react-markdown` 0.14.0 — Markdown primitive
- `@assistant-ui/react-lexical` 0.2.0 — Lexical 富文本输入 + directive chip
- `@assistant-ui/react-syntax-highlighter` 0.14.0 — 代码高亮工厂
- `@assistant-ui/core` — `AssistantRuntimeProvider`, `ThreadMessageLike`
- `vite` 5.x (Node 18 compatible, **not** latest which needs Node 20+)
- `@vitejs/plugin-react` 4.x (compatible with vite 5)

### Version constraints

Node.js on this server is 18.x. Vite 6+ requires Node 20+, so pin:
```json
"vite": "^5.4.21",
"@vitejs/plugin-react": "^4.7.0"
```

### Import paths (non-obvious)

```typescript
// AssistantRuntimeProvider is NOT in @assistant-ui/react main index
import { AssistantRuntimeProvider } from "@assistant-ui/core/react";

// Thread pre-styled component
import { Thread } from "@assistant-ui/react-ui";

// CSS (subpath export, not dist/ path)
import "@assistant-ui/react-ui/styles/index.css";

// ExternalStoreRuntime IS in main index
import { useExternalStoreRuntime } from "@assistant-ui/react";
```

## Build

```bash
npm run build   # outputs inst/www/shinyAssistantUI.js + style.css
npm run dev     # watch mode
```

Commit the compiled `inst/www/` files — end users must not need npm.

### ⚠️ 改完 R 或 JS 必须 `R CMD INSTALL .` 再测(否则测的是旧包)

示例 app 和验证脚本都用 `library(shinyAssistantUI)` 启动 —— 它加载**已安装**的包
(`~/R/.../library/shinyAssistantUI`,字节码 .rdb),**不是**开发树源码。所以:

- 改 **R**(`R/*.R`)后:`npm run build` 不够,必须重装。
- 改 **JS**(`srcjs/*`)后:`npm run build` 只更新**开发树** `inst/www/`,已安装包的 `www/`
  仍是旧的 —— htmlwidget 经 `system.file("www", package=...)` 从**已安装**位置取 JS,
  所以浏览器拿到的还是旧 bundle。也必须重装。

```bash
npm run build                                        # 先编 JS 到 inst/www/
R CMD INSTALL --no-multiarch --with-keep.source .    # 再把 R + inst/www/ 一起装进库
```

顺序:**先 build 再 install**(install 会把 `inst/www/` 拷进已安装包)。
`devtools::load_all(".")` 只对**当前** R 进程生效,对 `callr::r_bg` 起的示例 app **无效**
(那是独立进程,走 `library()` 读已安装包)。

血泪教训:曾因忘记重装,连续多轮验证跑的都是昨天的旧包,`get_server_info`/`on_task`
等新代码"没生效"排查半天。改完即装。

## 测试

纯逻辑抽到独立模块（无 React/DOM 强耦合）：`srcjs/helpers.ts`（纯函数）、`srcjs/error-boundary.tsx`（ErrorBoundary class）。bridge.ts 用全局 `Shiny`，mock 即可测。

```bash
npx vitest run    # 全部 JS 测试（92 用例，5 文件）
```
```r
# R helper 测试（tests/testthat/test-helpers.R，13 测试）
devtools::load_all("."); testthat::test_dir("tests/testthat")
```

- **`helpers.test.ts`（43 用例）**：`expandSlashCommands`（前缀冲突）、`safeUrl`（XSS 白名单）、`markStaleToolCalls`、`stripAttachmentData`、`extractAttachments`、`preprocessStreamingMarkdown`、`detectSlashTrigger`、`storageKey`、`makeThreadId`、`applyEdit`（onEdit 截断三分支：null/命中/找不到）
- **`bridge.test.ts`（13 用例）**：多线程路由、缺 threadId 不串台 + warn、setRunCallbacks 隔离、多 widget inputId 隔离、sessions 缓冲回放、出站消息。mock `globalThis.Shiny`
- **`dom.test.tsx`（8 用例，jsdom）**：`createRemovalWatcher`（el 移除触发 unmount、disconnect、无父节点）、`ErrorBoundary`（抛错降级、resetKey 恢复/不误恢复）。文件顶部 `// @vitest-environment jsdom`
- **`runtime.test.tsx`（12 用例，jsdom）**：`useShinyRuntime` hook 集成测试。renderHook + mock `globalThis.Shiny`（捕获 handler + 记录 setInputValue）+ 真实 `useExternalStoreRuntime`。用 `fireR(type, data)` 模拟 R 回消息。覆盖：onNew 基本流、chunk 累积、done 落盘、onError、thinking 累积、tool 流式三段（start/delta/result）、ellmer 整包 tool-call、多线程隔离、多 tab storage 守卫（active 不覆盖 + 非活动同步）、跨线程 run 收尾隔离（切线程后旧线程 done 不清当前 running）。状态读 `runtime.thread.getState().messages` + localStorage
- **`approval-registry.test.ts`（9 用例）**：`srcjs/approval-registry.ts`（从 AssistantUI.tsx 抽出的审批 handler 注册表）。覆盖多 widget 隔离 HIGH 修复核心：按 inputId 路由、后注册 widget 不覆盖前者（修复前单例串台根因）、卸载只删自己不误清他者、多 widget 缺 inputId 返回 null 不猜不串台、单 widget fallback、重注册更新
- **R 覆盖**：`.attachment_text_sections`、`.claude_msgs_to_thread`
- `vitest.config.ts`：`include: srcjs/**/*.test.{ts,tsx}` + react plugin。**必须限定 include**——否则抓到 node_modules 里 @assistant-ui 源码自带测试（需 jsdom）报错
- **测试踩坑**：jsdom 的 `StorageEvent` dispatch **不会自动改 localStorage**——测多 tab 同步需先 `localStorage.setItem` 再 dispatch（否则 `loadMessages` 读空值，测试假阳性）
- **`runSeqRef`/`isLatestRun` 守卫的真实作用域**：bridge 的 `callbacksMap` 每线程只存最新 callbacks，R 消息经 `routeCallback` 总走最新——所以"同线程旧 run 的 done"在此模型下**不可构造**（能被调到的 onDone 必是最新 run 的）。守卫真正防的是**跨线程** stale：切线程后旧线程 handler 的 done 到达，靠 `currentThreadIdRef===threadId` 不误清当前线程 running。测试按此有效场景写
- **仍未单测**：`parseInline`（返回 JSX，纯渲染）、index.tsx factory 的 HTMLWidgets 胶水（纯逻辑已抽到 helpers/error-boundary 单测）。审批**逻辑**已单测（approval-registry），`examples/13_dual_widget_approval.R` 供 UI 视觉确认
- `node_modules/v18` 路径已失效，`package.json` scripts 改用 `vite build`（继承 nvm Node 24）

## 浏览器端到端验证（chromote/CDP，真实无头 Chromium）

`shiny::testServer()` 跑不出浏览器专属故障（async promise、reactive flush、Lexical
contenteditable、web-component 时序）。用 `chromote` 驱动真实无头 Chromium，读 DOM 真值断言。
脚本在 `tests/verify/`（已 `.Rbuildignore` 排除，不参与 R CMD check）：

```r
Rscript tests/verify/verify_e2e.R       # 15 项:流式/thinking/工具卡/sub-agent 层级/建议/附件/侧边栏
Rscript tests/verify/verify_approval.R  # 5 项:审批卡片→点 Yes→R 异步收到→回 result→后续文本
```

- **驱动方式**：`callr::r_bg` 后台起 app（固定端口）→ `ChromoteSession$new()` → 聚焦
  contenteditable（`inputId=chat_input`）→ CDP `Input$insertText` 输入 + `dispatchKeyEvent`
  Enter 提交 → `Runtime$evaluate` 读 DOM。**必须走 composer 提交**（`onNew` 才注册 startRun
  callbacks；直接 `setInputValue` 会因无 callbacks 丢弃 R 回消息）。
- **D2 断言**：`[data-tool-depth]` / `[data-parent-tool-call-id]` 属性；实测 depth map
  `[{d:0,p:null},{d:1,p:parent-1},{d:1,p:parent-1},{d:2,p:child-2}]`。
- 每次 navigate / click 后 `Sys.sleep()`（CDP 异步 + WebSocket 往返非即时）。用完
  `b$close(); proc$kill()` 防端口泄漏。

## R package

```r
devtools::load_all()   # load for dev
devtools::check()      # CRAN checks
devtools::build()      # build tarball
```

`.Rbuildignore` excludes `node_modules/`, `srcjs/`, `package.json`, `vite.config.ts`, `examples/`.

## Gotchas

### useRef lazy initialization（关键）

**不要** 写 `useRef(sideEffectFn())`——参数在**每次 render** 都会被求值，即使 `useRef` 只用第一次的值。凡是初始化有副作用（注册 handler、创建连接等）的 ref，必须用懒初始化模式：

```typescript
// ❌ 错误：createShinyBridge 每次 render 都会被调用
const bridge = useRef(createShinyBridge(inputId));

// ✅ 正确：只在第一次调用
const bridge = useRef<ShinyBridge>(null!);
if (!bridge.current) bridge.current = createShinyBridge(inputId);
```

**背景**：这个错误曾导致一个难以定位的 bug。`createShinyBridge` 在每次 re-render 时都重新调用 `Shiny.addCustomMessageHandler`，把 Shiny 的 handler 替换成了新 bridge 的闭包（`currentCallbacks = null`）。`useRef` 仍然持有第一个 bridge，`setRunCallbacks` 也写入第一个 bridge，但 chunks 到达时触发的是最新 handler 的闭包——callbacks 为 null，消息被静默丢弃，表现为只有加载动画、没有回复。

### R 端接收 JS 消息的属性名用 camelCase

JS 通过 `Shiny.setInputValue` 发送 `{ threadId, text, ... }`，R 端用 `msg$threadId`（camelCase），**不是** `msg$thread_id`。Shiny 保留 JSON 属性名，不做任何大小写转换。

### @assistant-ui/tap 生产模式 tapEffectEvent 陈旧回调（关键）

`tapEffectEvent` 在 `process.env.NODE_ENV === "production"` 时直接返回 `callbackRef.current`（旧回调），而不是稳定包装函数。导致 `@` mention 的 `handleKeyDown` 里捕获的 `open` 永远是上一帧的 `false`，键盘导航完全失效。

**修复**：`vite.config.ts` 里加 transform 插件，把 `@assistant-ui/tap` 的 `env.js` 替换为 `export const isDevelopment = true`：

```typescript
{
  name: "patch-tap-is-development",
  transform(code, id) {
    if (id.includes("@assistant-ui/tap") && id.endsWith("/env.js"))
      return { code: "export const isDevelopment = true;\n", map: null };
  },
},
```

详见 `.claude/docs/tap-production-bug.md`。

### useEffect 依赖数组与对象引用稳定性

`useEffect([objState])` 每次 render 都比较引用。若 setState 每次传新对象（即使值相同），effect 每次都触发。例如 `setSlashState({ query, offset })` 每次 keyup 创建新对象 → 触发重置焦点的 effect → 方向键焦点归零。

**修复**：用 functional update，值不变时返回 `prev`（同一引用）：

```typescript
setSlashState(prev => {
  if (prev && prev.query === next.query && prev.offset === next.offset) return prev;
  return next;
});
```

详见 `.claude/docs/react-useeffect-object-identity.md`。

### 工具结果卡片含 Shiny input/output 时的 DOM 操作顺序

若未来工具结果卡片内嵌入含 Shiny input/output 的 HTML（通过 `session$sendCustomMessage` 推送），JS 端插入 DOM 时**必须**按如下顺序操作，否则报 `"Duplicate binding for ID ..."` 错误：

```javascript
Shiny.unbindAll();
// DOM 操作（insertAdjacentHTML、append、replaceWith 等）
Shiny.initializeInputs();
Shiny.bindAll();
```

R 端如果发送的是 Shiny tag 对象（含依赖），必须先用 `htmltools::renderTags()` 打包：

```r
rendered <- htmltools::renderTags(my_shiny_tag)
session$sendCustomMessage("tool-result", list(
  html         = rendered$html,
  dependencies = rendered$dependencies
))
```

JS 端用 `Shiny.renderHtml(html, $([]), dependencies).html` 解析后再插入 DOM。

**纯静态 HTML**（无 Shiny input/output）不需要此序列，直接 `innerHTML` 即可。

### CRITICAL: coro::async 内禁止 if-as-expression 赋值

**不要** 在 `coro::async(function() { ... })` 函数体内用 `x <- if (cond) a else b`：

```r
# ❌ 报错：Can't assign the result of a if expression.
full_message <- if (nzchar(text_sections)) paste0(text_sections, "\n\n", message) else message

# ✅ 正确：改用普通 if 语句
full_message <- message
if (nzchar(text_sections)) full_message <- paste0(text_sections, "\n\n", message)
```

coro 的 AST 转换器不支持 if 表达式作为右值。此限制同样适用于 `<-` 右侧的所有复杂表达式（switch、tryCatch 等作为右值时也可能触发）。普通函数（非 async）不受此限制。

## CRITICAL: R 示例 app 必须用 bslib，禁止用 Shiny 原生布局函数

所有 `examples/` 下的 Shiny app **必须**使用 `bslib` 的布局函数，**禁止**使用 Shiny 原生函数：

| 禁止使用 | 替换为 |
|---|---|
| `fluidPage()` | `bslib::page_fluid()` |
| `navbarPage()` | `bslib::page_navbar()` |
| `sidebarLayout()` | `bslib::layout_sidebar()` |
| `column()` / `fluidRow()` | `bslib::layout_columns()` |
| `wellPanel()` | `bslib::card()` |

示例写法：
```r
library(bslib)
ui <- page_fluid(
  layout_columns(
    col_widths = c(3, 9),
    card(...),          # 左栏
    assistantUIOutput("chat", height = "80vh")
  )
)
```

## 新增功能批次（2026-07-04 batch 2）

以下功能本批次实现并经真实浏览器（chromote）端到端验证:

| 功能 | R 接口 | 前端 | 验证脚本 |
|------|--------|------|----------|
| 线程重命名 | `assistantUIServer(on_rename=)` + 侧栏 `…`→Rename | `renameThread` + `.aui-thread-rename-input` | `verify_rename.R` 5/5 |
| 消息时间戳 | `assistantUIServer(show_timestamps=TRUE)` | `formatMessageTime()` 从 id 解析 + `MessageTimestamp` | `verify_timestamps.R` 2/2 |
| HTML 沙箱 | 工具 `resultType="html"`(默认沙箱)+ `annotations$htmlSandbox=FALSE` opt-out | `<iframe sandbox=''>` 隔离 | `verify_html_sandbox.R` 3/3 |
| 引用/来源 | handler 参数 `on_source(url, title, id)` | `source` content part + `SourceCite` 脚注 | `verify_sources_image.R` |
| 原生图像 part | handler 参数 `on_image(image)` | `image` content part + `img.aui-message-image` | `verify_sources_image.R` |
| 消息队列 | (纯前端)运行中 composer 时钟按钮 | `messageQueueRef` + `onDone` flush | `verify_queue.R` 4/4 |
| Artifacts 侧面板 | handler 参数 `on_artifact(id, title, content, type, lang)` | `artifacts` state + `ArtifactPanel`(右侧 45%) | `verify_artifacts.R` 4/4 |

**主题风格示例**:`examples/15_style_base.R` … `20_style_perplexity.R` 用 `assistant_theme()` 复刻官网 6 种风格。
**编号**:`examples/` 全部文件加 `NN_` 序号前缀(01–25),`verify_examples.R` 动态 `list.files` 自适应。

**新回调传法**:handler 用 `...` 捕获,或显式声明形参(`server.R` 按 `names(formals(handler))` 过滤注入)。`on_source`/`on_image`/`on_artifact` 与 `on_chunk` 等同级,在 handler 执行期间调用。

**关于 assistant-ui/ink**:官网 Ink 项目是 assistant-ui 的**终端(React Ink / ANSI)渲染目标**,与本项目(浏览器 htmlwidget,渲染 `@assistant-ui/react` + DOM)是**不同渲染栈**,无法集成进 Shiny widget。二者共享同一 runtime 概念但 UI 层完全不同。若需终端 AI 聊天,应独立用 `@assistant-ui/react-ink`,而非本包。

## Known gaps / future work
- **Theme customization API (CSS variables)** — ✅ **已实现（2026-07-04）**。`assistant_theme()` 构造器（R/theme.R，`col2rgb`→HSL 分量，已是分量则幂等透传，`radius` 非色透传）+ `assistantUIServer(theme=, dark_mode=)`（`dark_mode` ∈ FALSE/TRUE/"auto"）。`config$theme` 经 `themeToCssVars()`（srcjs/helpers.ts）在 `index.tsx` factory 的 `applyTheme()` 注入 widget `el` 的 inline CSS 变量（`--aui-*`，per-widget scoped），`dark_mode` 切 `dark` 类（"auto" 用 matchMedia，teardown 清理监听）。测试:R 9 组、JS 5 组、浏览器 7/7（`tests/verify/verify_theme.R`）。示例 `examples/08_theming.R`。
- **Gap 1: 流式 tool call 参数（input_json_delta）** — ✅ **ClaudeAgentSDK 路径已实现**。三段式：`content_block_start`→`on_tool_call_start`（建空壳 part）、`input_json_delta`→`on_tool_call_delta`（逐字追加 argsText）、`content_block_stop`→`on_tool_call`（补全解析后 args，幂等更新同一 part）。链路：`handlers.R` StreamEvent → `server.R` `:tool-call-start`/`:tool-call-delta` 消息 → `bridge.ts` `onToolCallStart`/`onToolCallDelta` → `runtime.ts` 追加 `argsText` → `GenericToolCard` 自动逐字渲染（已优先读 argsText）。
  - **ellmer 仍阻塞（复核于 2026-07-04，ellmer 0.4.1.9000 开发版）**：ellmer `stream="content"` 仍只把完整的 `ContentToolRequest` 作为整体对象吐出，`stream_content.ProviderAnthropic` 把逐字 `input_json_delta` 吞掉，公开 API 摸不到，工具参数只能完整后整体显示。需 ellmer 上游改动。`server.R` 用 `names(formals(handler))` 过滤——ellmer handler 不声明 `on_tool_call_start/delta` → 自动不注入 → 走整包新建路径，无副作用。
- **Gap 2: Sub-agent 层级展示** — ✅ **已实现（2026-07-04）**。多级 agent 调用时展示嵌套工具树。采用轻量方案（未上真 sub-thread runtime）：R 端 `on_tool_call` 的 `annotations` 带 `parentToolCallId`（`on_tool_call` 已原样透传 annotations，无需改 R），前端 `computeToolDepth()`（`srcjs/helpers.ts`，walk parent 链 + 环检测 + maxDepth 封顶）算深度，`GenericToolCard` 按 depth 缩进（`marginLeft=depth*20px` + `borderLeft` 连接线），并输出 `data-tool-depth` / `data-parent-tool-call-id` 属性。模块级 `_toolParentRegistry` 按 inputId 命名空间隔离多 widget。**未用**官方 `Unstable_PartsGroupedByParentId`——因本项目 tool-call 是独立 assistant 消息（每 toolCallId 一条 `tool-${id}` 消息），CSS 缩进方案不改 runtime 数据模型、零迁移风险，且已通过真实浏览器验证（`tests/verify/verify_e2e.R` depth map `[0,1,1,2]` 正确）。
- Interrupt support — **已实现 Level 2**（两条路）：

  | 路径 | 机制 | 状态 |
  |------|------|------|
  | ClaudeAgentSDK | `client$interrupt()` → CLI 子进程终止 HTTP → drain → ResultMessage | ✅ Level 2 |
  | ellmer | `stream_controller` + `register_cancel` → httr2 callback 返回 FALSE | ✅ Level 2（需 ellmer ≥ 0.4.0.9000）|

  **server.R 机制**：`cancel_fns` env 存储每线程 cancel fn；cancel observer 收到 Stop 信号后立即调用注册的 fn（`ctrl$cancel()` 或 `client$interrupt()`），再 auto-deny 所有挂起的 `wait_for_approval` promise 防止死锁。

  **关键 bug 已修**：
  - `onCancel` 不再清 `streamingIdRef.current`（否则残余 chunk 创建第二 AI 头像）
  - `onCancel` 不再清 `setRunCallbacks(null)`（否则 `on_tool_result("Interrupted")` 被静默丢弃，tool card 卡在 running）
  - ExtendedTask func 必须始终返回 promise（否则 `as.promise(NULL)` 报错）
  - **流式工具参数中断卡死**（流式参数功能引入后放大）：用户在工具参数流式途中（`content_block_stop` 前）点 Stop，drain 只认 ResultMessage、漏掉半截 tool block，卡片永久转圈。修复双保险：① R `handlers.R` interrupted 时立即 `interrupt_tool_blocks()` 对所有未审批 block 发 "Interrupted" result；② JS `runtime.ts` onDone 用 `markStaleToolCalls()` 兜底标记任何 `result===undefined` 的 tool-call part（与 localStorage 恢复逻辑共用 helper）。
  - **drain 无超时**：interrupt 后若 SDK 子进程崩溃不再吐 ResultMessage，repeat 死循环、ExtendedTask 永不 resolve。修复：`DRAIN_MAX_EMPTY_POLLS=200`（≈10s）空轮询封顶强制退出。
  - **cancel auto-deny 跨线程**：`approval_resolvers` 原以 toolCallId 为键无 thread 信息，取消线程 A 会否决线程 B 的挂起审批。修复：resolver 存 `list(fn, thread)`，cancel 仅否决 `entry$thread == tid` 的（`make_wait_for_approval(thread_id)` 工厂绑定）。

  **资源/session 健壮性已修**：
  - **ClaudeSDKClient 子进程泄漏**：长 Shiny session 不断新建线程累积子进程，从不回收。修复：`make_claude_handler` 经 `attr(handler, "cleanup")` 暴露 `disconnect()` 全部 client 的清理函数，`server.R` 在 `session$onSessionEnded` 调用。
  - **进程内导入 session 不 resume**：`make_claude_handler` 与 `make_claude_session_loader` 各持独立 `session_map` 内存副本，loader 写盘不同步到 handler，进程内导入历史 session 续聊丢上下文。修复：handler 的 `get_client` 经 `read_session_id()` 在内存 miss 时回读磁盘（磁盘为单一真相源）。
  - **drain 超时改墙钟**：原"连续空轮询计数"在中断后子进程持续吐非-ResultMessage 垃圾事件时会被不断重置而失效（永不超时）。改为 `Sys.time()` 墙钟封顶（`DRAIN_TIMEOUT_SECS=10`），覆盖"崩溃静默"和"持续吐垃圾"两种场景。

  **安全 / 数据完整性已修**：
  - **附件 base64 撑爆 localStorage**：图片/文件 base64 data 原样落盘，一张几 MB 图即触发 QuotaExceededError → 整个 thread 历史无法落盘 → 刷新丢失。修复：`saveMessages` 经 `stripAttachmentData()` 落盘前剥离 image/file 的大 data 字段（内存态仍持完整 data 供当前会话显示 + 发往 R），只持久化元信息。
  - **localStorage 配额静默吞**：所有 `save*` 函数 `catch {}` 完全静默，配额满后数据丢失用户无感。修复：catch 改 `console.warn` 告警。
  - **markdown link `javascript:` XSS**：工具结果 markdown（可能来自 WebFetch 抓取的不可信网页）的 `[text](url)` 不过滤 scheme，`javascript:` URL 可点击执行。修复：`parseInline` 经 `safeUrl()` 白名单（http/https/mailto/tel/相对路径），不安全 scheme 降级为纯文本。`html` resultType 的 `dangerouslySetInnerHTML` 仍是文档化信任契约（责任在调用方，仅用于可信输出）。
  - **file 类附件静默丢弃**：两 handler 只消费 image/text，用户上传 PDF/xlsx 等 file 类时 UI 显示 chip 但 AI 完全无感知。修复：共享 helper `.attachment_text_sections()` 把 file 名/类型作为文本提示注入（`[Attached file: name (type) — binary content not directly readable]`），AI 至少知道有文件、能回应，并消除两 handler 的重复代码。

  **健壮性 / 性能小修**：
  - **多 tab localStorage 互相覆盖**：两个 tab 同 inputId 各持独立 state，last-write-wins 覆盖对方新建/删除的线程。修复：`runtime.ts` 加 `storage` 事件监听，跨 tab 同步 threads/archived 列表；某 thread 消息仅在它非本 tab 活动线程时同步（活动线程本地优先，防覆盖流式中状态）。server 权威模式跳过。
  - **`preprocessStreamingMarkdown` O(n²)**：每个流式 token 都 split+遍历全文，长回复卡顿。修复：无 `|` 时快速短路直接返回（绝大多数 markdown 无表格）；顺带修单 `|` / `||` 行被误判为表格（`line.length > 2` + `cols > 0` 校验）。
  - **`onToolResult` 定位不一致**：原用 `content[0]` 假设 tool-call 在首位，与 `markStaleToolCalls`/`onToolCallDelta` 的"按 type findIndex"不一致，未来多 part 消息会失配。修复：统一为 `findIndex(type==="tool-call" && toolCallId 匹配)`。

  **消息回调 / 资源生命周期已修**：
  - **onEdit 编辑后 user 消息消失**（HIGH）：外部存储模式下 messagesMap 是唯一真相源，onEdit 原来只截断不重新插入编辑后的 user 消息 → 编辑后气泡消失、界面变"截断点→assistant 回复"。修复：截断后重新插入 user 消息（含附件），抽 `extractAttachments()` helper 与 onNew 共用；parentId 找不到时保守保留全部不清空。
  - **run 重入致 callbacks 抢删**（MEDIUM）：同 thread run A 未结束又起 run B，run B 覆盖 callbacks 后 run A 的 onDone 无条件 `setRunCallbacks(null)` 删掉 run B → run B 回复丢失。修复：`runSeqRef` per-thread run 序号 + `isLatestRun()` 守卫，仅最新 run 的 onDone/onError 才注销 callbacks。
  - **slash 命令前缀冲突**（MEDIUM）：`/test2` 被 `/test` 子串命中错误展开。修复：抽 `expandSlashCommands()` helper，按 name 长度降序 + 词边界正则 `/(?![\w-])` 匹配；用函数式 replace 避免 prompt 含 `$` 被解释。
  - **多 tab 同步保护维度**：storage 同步 guard 原用"是否当前活动 thread"，漏了后台并发 run 的非活动 thread（流式中本地领先磁盘会被覆盖）。修复：`activeRunsRef` 集合记录正在 streaming 的 threadId，guard 改为"正在跑 OR 当前活动"才跳过同步。
  - **ellmer_store 并发丢数据**（MEDIUM）：多 worker 共享 .sqlite 写-写撞锁立即 `SQLITE_BUSY`。修复：`PRAGMA busy_timeout = 5000` 重试；`load` 加 tryCatch 损坏数据降级 NULL（`.ellmer_chat_set_state` 调用点已有 tryCatch 回退 fresh chat）。
  - **index.tsx React root 泄漏 + ErrorBoundary 不恢复**（MEDIUM/LOW）：widget 无 unmount 钩子，modal 反复开关累积孤儿 root + Shiny handler；ErrorBoundary 出错后永久卡错误态。修复：`MutationObserver` 监听 `el.isConnected` 变 false 时 `root.unmount()`；ErrorBoundary 加 `resetKey`（renderCount），renderValue 重渲染时清错误态恢复。
  - onReload 残留调试 `console.log` 已删；onEdit 编辑带附件不再静默丢弃（走 extractAttachments）。

  **多实例隔离 / 审批 / 路由已修**：
  - **多 widget 审批串台死锁**（HIGH）：模块级 `_toolApprovalHandler` 单例，两个 chat widget 同页时后挂载者覆盖前者 → A 的审批发到 B 的 inputId → B 找不到 resolver → A 永久死锁（前端却乐观显示 ✓ Approved）。修复：改 `Map<inputId, handler>`，R 端 `on_tool_call` 的 annotations 注入 `inputId`，card 经 `annotations.inputId` 定位（`resolveApprovalHandler`，单 widget 缺 inputId 时 fallback 唯一项）。卸载只 `delete` 自己的 key。
  - **onEdit parentId 陈旧仍 startRun**（MEDIUM，流式参数修复后引入）：`setMessagesMap` 里 `return prev` 拦不住其后同步的 `startRun`，产生孤儿 assistant 回复 + UI/R 发散。修复：`aborted` 标志在 updater 里置位，updater 后据此跳过 startRun。
  - **MutationObserver 监听 body 全子树**（MEDIUM 性能）：被 widget 自身流式 DOM 变动高频自触发。修复：改监听 `el.parentNode` 的 childList（非 body subtree），只关心 el 是否被移除。
  - **bridge 缺 threadId fallback 掩盖错误**：原静默路由到"第一个"回调，多线程并发会投递错线程。修复：抽 `routeCallback()`，单线程回退唯一项，多线程 `console.warn` + 放弃。
  - **审批 UI LOW 批次**：删重复 "Yes" 选项（copy-paste bug）；`suggestionIdx` 加 R 端边界校验（`>= 0 && < length`）防越界抛错；`send_tool_call`/`send_tool_result` 注释提示非默认 thread 须显式传 `thread_id`。
  - **已知限制（未改，影响低）**：审批"已发送"状态仅存 `useState`，切 thread 再切回会重现审批按钮（R 端 no-op 安全，仅 UI 困惑）；run 重入时 `streamingIdRef` 共享致气泡视觉碎裂（callbacks 守卫已防数据丢失）。

## 版本稳定性评估

当前版本已实现 ClaudeAgentSDK 核心需求，基础功能稳定：
- ✅ 多线程对话 + localStorage 持久化
- ✅ 工具调用 + 7 种结果类型（table/markdown/code/image/file/html/auto）
- ✅ 工具审批（requiresApproval）+ 用户取消
- ✅ 附件上传（image/text/file）
- ✅ ExtendedTask 异步 + reactive flush
- ✅ 主要 bug 已修复（duplicate ID、localStorage 腐败、useRef 懒初始化）
- ✅ 生产模式 tap bug 已绕开
- ✅ Level 2 打断（ClaudeAgentSDK drain 模式 + ellmer stream_controller）
- ✅ localStorage 历史恢复：pending tool card 自动标记为 "Session ended"
- ✅ ClaudeAgentSDK session 持久化：`client$session_id` 自动 capture，`client$resume()` 跨进程恢复上下文

**稳定性**：高。核心流程经过测试，无已知阻塞性问题。Gap 1/2 为增强功能，不影响当前使用。
