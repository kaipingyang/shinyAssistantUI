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

## Known gaps / future work

- Slash command `/` menu (cmdk installed, not yet wired up)
- File attachment handling (bridge has `attachments` field, UI not yet configured)
- Tool call display cards
- Thread history list (`ThreadListPrimitive`)
- Theme customization API (CSS variables)
- Interrupt support (`on_chunk` cancellation)
