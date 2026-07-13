# shinyAssistantUI

A Shiny htmlwidget that wraps [`@assistant-ui/react`](https://github.com/assistant-ui/assistant-ui) — giving Shiny apps a full-featured AI chat UI with streaming output, slash command menu, file attachments, and tool call display.

Backend-agnostic: works with [ClaudeAgentSDK](https://github.com/kaipingyang/ClaudeAgentSDK), [ellmer](https://github.com/tidyverse/ellmer), or any R-based AI backend.

## Installation

```r
# GitHub (development)
remotes::install_github("kaipingyang/shinyAssistantUI")
```

## Usage

```r
library(shiny)
library(shinyAssistantUI)

ui <- fluidPage(
  assistantUIOutput("chat", height = "80vh")
)

server <- function(input, output, session) {
  assistantUIServer("chat", handler = function(message, on_chunk, on_done, on_error) {
    # Call any AI backend here
    # Stream tokens back with on_chunk(), finish with on_done()
    on_chunk("Hello! You said: ")
    on_chunk(message)
    on_done()
  })
}

shinyApp(ui, server)
```

### With ClaudeAgentSDK

```r
library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

ui <- fluidPage(
  assistantUIOutput("chat", height = "80vh")
)

server <- function(input, output, session) {
  client <- ClaudeSDKClient$new(claude_agent_options())

  assistantUIServer("chat", handler = function(message, on_chunk, on_done, on_error) {
    client$connect()
    client$send(message)
    client$receive_response_async(
      on_message = function(msg) {
        if (inherits(msg, "AssistantMessage")) {
          for (block in msg$content) {
            if (inherits(block, "TextBlock")) on_chunk(block$text)
          }
        }
        if (inherits(msg, "ResultMessage")) on_done()
      }
    )
  })
}

shinyApp(ui, server)
```

### With bslib

```r
library(bslib)

page_sidebar(
  title = "My AI App",
  sidebar = sidebar(...),
  bslib::card(
    full_screen = TRUE,
    assistantUIOutput("chat", height = "100%")
  )
)
```

### In RStudio (Claude Code addin)

Bring an agentic Claude Code chat into the IDE instead of the terminal CLI. Install the
package, then use the **Addins → "Claude Code Chat"** menu (or call it directly):

```r
shinyAssistantUI::claude_addin()               # dialog, rooted at the active project
shinyAssistantUI::claude_addin(viewer = "pane") # dock in the Viewer pane
```

- **Project-rooted & agentic**: launches at the active RStudio project (`cwd`), so Claude's
  `Read`/`Edit`/`Bash`/`Grep` tools operate on your real files.
- **Context-aware**: the active editor file + selection are appended to Claude Code's system
  prompt, so you can ask "explain this" / "refactor the selection" without pasting code.
- **Safe by default**: file edits and shell commands are gated by the in-app approval card
  (`permission_mode = "default"`).
- Requires the [`ClaudeAgentSDK`](https://github.com/kaipingyang/ClaudeAgentSDK) package and a
  working `claude` CLI. Runs in the browser if called outside RStudio.

## API

### `assistantUIOutput(outputId, width, height, ...)`

Creates the chat widget placeholder in UI. Standard htmlwidget output function.

### `assistantUIServer(id, handler)`

Server-side module. `handler` is called each time the user sends a message:

```r
handler = function(message, on_chunk, on_done, on_error) {
  # message   — character, the user's text
  # on_chunk  — function(text): stream a token
  # on_done   — function(): signal completion
  # on_error  — function(msg): surface an error in the UI
}
```

### Rich message features

The `handler` receives optional callbacks (declare them as params, or use `...`):

```r
handler = function(message, on_chunk, on_done,
                   on_source, on_image, on_artifact, ...) {
  on_chunk("Based on the sources, the answer is 42. ")
  on_source("https://en.wikipedia.org/wiki/42", title = "Wikipedia: 42")  # citation footnote
  on_image("data:image/png;base64,...")                                   # inline image
  on_artifact(id = "doc-1", title = "Report", type = "markdown",          # side panel
              content = "# Report\n...")                                  # type: markdown|code|html|text
  on_done()
}
```

`assistantUIServer()` also accepts:

- `show_timestamps = TRUE` — show each message's send time (HH:MM).
- `on_rename = function(thread_id, title)` — called when a thread is renamed in the sidebar (title is already persisted client-side; use this to sync a server-side store).
- **Message queue** — while a reply streams, a clock button appears next to Stop; typing + clicking it queues the message, auto-sent when the current reply finishes.
- **HTML tool results** (`resultType = "html"`) render in a sandboxed iframe by default (no scripts, isolated) — set `annotations$htmlSandbox = FALSE` to opt out for trusted interactive HTML.

See `examples/21_artifacts.R` … `examples/25_message_queue.R`.

### Website styles

`examples/15_style_base.R` … `examples/20_style_perplexity.R` recreate the six
assistant-ui.com looks (Base, ChatGPT, Claude, Grok, Gemini, Perplexity) using
`assistant_theme()`.

### Theming
Recolor the chat to match your app with `theme` and `dark_mode`. Colors accept
any R format (hex, named, `rgb()`); they are converted to assistant-ui's
semantic tokens and injected as **scoped** CSS variables (each widget can have
its own theme).

```r
library(shinyAssistantUI)

assistantUIServer(
  "chat",
  handler   = my_handler,
  theme     = assistant_theme(
    primary            = "#2563eb",   # send button, user bubble
    primary_foreground = "#ffffff",
    background         = "#f8fafc",
    accent             = "#dbeafe",
    radius             = "0.75rem"    # corner radius (CSS length, not a color)
  ),
  dark_mode = FALSE                   # FALSE | TRUE | "auto" (follow OS)
)
```

`assistant_theme()` tokens: `background`, `foreground`, `primary`,
`secondary`, `accent`, `muted`, `destructive`, `card`, `popover` (each with a
`*_foreground` companion), plus `border`, `input`, `ring`, and `radius`.
See `examples/08_theming.R`.

## Architecture

```
User input (React Composer)
  └─► Shiny.setInputValue → R observeEvent → your handler
        └─► on_chunk(text) → sendCustomMessage → React ExternalStoreRuntime
              └─► @assistant-ui/react renders streaming message
```

The React component (`@assistant-ui/react`) manages all UI state internally via Zustand. R communicates via `session$sendCustomMessage()` for streaming and `input$*` for user events — the standard htmlwidgets pattern.

## Development

Rebuild the JS bundle after editing `srcjs/`:

```bash
npm run build      # one-shot
npm run dev        # watch mode
```

Requires Node.js ≥ 18.

## License

MIT © Kaiping Yang
