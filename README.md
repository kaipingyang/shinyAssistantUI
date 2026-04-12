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
