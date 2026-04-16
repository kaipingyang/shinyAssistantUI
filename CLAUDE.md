# shinyAssistantUI — Developer Notes

## CRITICAL: 必须使用中文回复
所有回复必须使用中文，包括解释、分析、建议等。代码、命令、文件路径等技术内容保持原样。

Shiny htmlwidget wrapping `@assistant-ui/react`. R package + React/TypeScript frontend.

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
- `@assistant-ui/react` 0.12.x — runtime + primitives
- `@assistant-ui/react-ui` 0.2.x — pre-styled `Thread` component
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

## Known gaps / future work

- File attachment handling (bridge has `attachments` field, UI not yet configured)
- Theme customization API (CSS variables)
- Interrupt support (`on_chunk` cancellation)
