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

## Known gaps / future work

- Slash command `/` menu (cmdk installed, not yet wired up)
- File attachment handling (bridge has `attachments` field, UI not yet configured)
- Tool call display cards
- Thread history list (`ThreadListPrimitive`)
- Theme customization API (CSS variables)
- Interrupt support (`on_chunk` cancellation)
