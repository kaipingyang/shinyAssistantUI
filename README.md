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

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "AI Assistant"
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

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "Claude Assistant"
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
- **Context-aware**: the active editor file + selection are sampled again for every new
  prompt (not frozen at addin startup). The composer shows the current file/line range with an
  eye toggle; click it to hide the active file (and any selection) from Claude for the next
  prompts, or show it again — the file reference and selection are only sent when the eye is on.
- **Workspace mentions**: type `@` to fuzzy-search files and folders. Entries stay
  literal (`@R/app.R`, `@R/app.R#L5-L10`, `@R/`); the search now includes Git-ignored
  entries too (e.g. a `dev/` folder), skipping only heavy package/cache dirs such as
  `node_modules`, `renv/library`, `.venv`, `__pycache__`, and `.Rproj.user`. The browser does
  not expand file contents.
- **Safe by default**: file edits and shell commands are gated by the in-app approval card
  (`permission_mode = "default"`). Which tools prompt is decided entirely by Claude Code (working-
  directory boundary, built-in read-only allowances, and your `.claude/settings.json` rules) — the
  addin simply renders whatever the CLI asks. To force a prompt for **every** (or specific) tool,
  use Claude Code's own permission config, e.g. in the project's `.claude/settings.json`:

  ```json
  { "permissions": { "ask": ["*"] } }
  ```

  `ask` rules also accept per-tool / per-path patterns such as `"Bash(rm*)"` or `"Read(/tmp/**)"`.
- Requires the [`ClaudeAgentSDK`](https://github.com/kaipingyang/ClaudeAgentSDK) package and a
  working `claude` CLI. Runs in the browser if called outside RStudio.

### Claude Code slash commands and skills

The Claude addin shows deterministic controls such as `/compact`, `/context`, `/clear`, and
`/mcp` separately from prompt-based skills. Selecting one of these controls—or submitting its
exact command directly—routes to the local Claude action handler and does not send a normal AI
message. Commands with arguments, such as `/compact focus on tests`, remain literal so Claude
Code can apply its own argument semantics.

`load_claude_skills()` discovers direct personal and project entries from
`~/.claude/skills/<name>/SKILL.md`, `~/.claude/commands/*.md`, and the corresponding `.claude/`
folders in the project. The menu labels their source as **Personal Skills**, **Project Skills**,
etc. Matching Claude Code, a skill beats a legacy command in the same scope, and a personal
entry beats a project entry with the same command name. `user-invocable: false` and
`skillOverrides: {"name":"off"}` hide entries. Marketplace caches are not recursively scanned;
active plugin, bundled, nested-project, and other live commands are supplied by the connected
Claude Code process with their proper names.

## API

### `assistantUIPage(..., title = NULL, padding = 0, suppress_bootstrap = TRUE)`

Creates a full-height standalone page for `assistantUIOutput()`. By default it suppresses
Bootstrap dependencies, matching the widget's scoped design system; set
`suppress_bootstrap = FALSE` only when descendants intentionally require Bootstrap. For
embedding inside an existing bslib app, keep using the host page layout instead.

### Permission mode controls

Handlers that advertise permission capabilities (including `make_claude_handler()`) show the
same per-thread permission mode in two places: a compact selector below the composer and a
**Settings** panel at the bottom of the thread sidebar. Dynamic choices are **Manual**
(`default`), **Plan** (`plan`), **Auto-edit** (`acceptEdits`), **Bypass**
(`bypassPermissions`), and **Strict** (`askAll`). Bypass runs all tools without permission
prompts and should only be used in trusted environments. Strict is the opposite — it prompts
for approval on **every** tool call (injecting `{"permissions":{"ask":["*"]}}`), keeping the
full approval card so you can "Always allow" safe tools as you go. **YOLO** (`yolo`) goes
further than Bypass: it drops the permission-prompt channel entirely (like the CLI's
`--dangerously-skip-permissions`) so **nothing** is ever asked — use only in fully trusted
environments. Permission changes are submitted silently and do not add chat bubbles.

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
  on_image(plot_data_uri(hist(rnorm(1000))))                              # inline chart (ggplot/base → PNG)
  on_artifact(id = "doc-1", title = "Report", type = "markdown",          # side panel
              content = "# Report\n...")                                  # type: markdown|code|html|text
  on_done()
}
```

`plot_data_uri(expr, width, height, res)` renders a plotting expression (base graphics, or a
ggplot2/lattice object — auto-printed) to a PNG `data:` URI for `on_image()`, so charts show inline
using R's own plotting (no client-side charting library is bundled). Interactive charts can go
through an `on_artifact(type = "html")` iframe (e.g. a plotly/htmlwidget snapshot).

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
