# shinyAssistantUI

A native Shiny output binding that wraps [`@assistant-ui/react`](https://github.com/assistant-ui/assistant-ui) — giving Shiny apps a full-featured AI chat UI with streaming output, slash command menu, file attachments, and tool call display.

Backend-agnostic: works with [ClaudeAgentSDK](https://github.com/kaipingyang/ClaudeAgentSDK), [ellmer](https://github.com/tidyverse/ellmer), or any R-based AI backend.

## How it maps to assistant-ui

| assistant-ui concept | shinyAssistantUI implementation |
|---|---|
| Surface | React Web inside a native Shiny output binding |
| Runtime | Custom `ExternalStoreRuntime` |
| Transport | Shiny inputs and custom messages over its WebSocket |
| Server | Backend-agnostic R handler |

This React Web + Shiny architecture does not require React Native, Ink, A2UI, AG-UI, or every
runtime adapter listed by assistant-ui. See the pkgdown
[Overview](https://kaipingyang.github.io/shinyAssistantUI/articles/shiny-assistant-ui.html) and
[ordered upstream alignment record](https://kaipingyang.github.io/shinyAssistantUI/articles/upstream-alignment.html).

## Installation

This development site tracks the `dev` branch. Install the matching development version explicitly:

```r
remotes::install_github("kaipingyang/shinyAssistantUI", ref = "dev")
```

GitHub's default branch is `main`, so omitting `ref` installs a different floating branch that may
not match this site. For production, replace `"dev"` with a validated release tag or full commit
SHA.

The installed R package already ships its compiled React, assistant-ui, CSS, and KaTeX assets, so
application users do **not** need Node.js, npm, shadcn, or the upstream assistant-ui CLI. Install
only the optional R backend used by the app. See the pkgdown
[Installation guide](https://kaipingyang.github.io/shinyAssistantUI/articles/installation.html) for
custom handlers, ellmer, ClaudeAgentSDK, codeagent, RStudio addin prerequisites, contributor builds,
and the current distribution/compatibility gaps.

The codeagent adapter keeps synchronous turn handling outside a small async
coroutine. The matching codeagent streaming implementation also uses a shared
small driver; both packages must be updated to receive the latency improvement.
Data Shield and enabled web citations still buffer text until their final
scan/render step. Remote workers use the library selected by `libpath`, not
automatically the host's newly installed codeagent. Stream callbacks are released
on errors, and closing a Shiny session cancels its own registered runs without
clearing other sessions' shared ellmer history. Remote JSONL transport preserves
split UTF-8 frames and surfaces connection/callback errors instead of silently
waiting or reporting success. The worker sleeps only when idle, not after every
ready promise callback. Both local stream drivers wait for asynchronous iterator
cleanup before releasing the turn, including callback failures and cancellation.
These changes do not eliminate ellmer's own per-fragment coroutine overhead:
the high-rate SSE benchmark still exposes a throughput limit under Shiny's default
deep-stack domains. See `tests/verify/verify_codeagent_latency.R` and
`tests/verify/verify_backend_handlers.R` for bounded, local-only regression gates;
the latter's `ellmer-direct` performance arm isolates the public ellmer API
without using a package handler.

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
- **Local diagnostics and performance**: the addin shows a compact Performance Orb and writes privacy-filtered operational summaries to `~/.claude_addin/diagnostics` by default. Logs are local only, retain at most 50 MiB / 7 days, and exclude prompts, responses, file paths, environment values, raw IDs, error text, and stacks. Use **Settings → Save diagnostic logs** to opt out; stop the existing Background Job and reopen the addin for the logging change to take effect. Hiding the Orb does not disable the memory guard. A high process-memory state pauses background warmup/automatic work but keeps explicit chat available while the session cgroup has safe headroom.
- **Reading the Performance snapshot**: **Refreshed** is when the browser received a snapshot, while **Process sampled**, **Tree sampled**, and **Session sampled** show the actual measurements and their ages in local time. Refresh retrieves the latest background sample; it does not force GC or refresh the slower tree/cgroup measurements. Missing timestamps from older servers are explicitly unavailable. Frame p95 and jank cover the latest 600 frame intervals, not input latency; long tasks count observations while the panel is open and show their availability rather than an unmeasured zero. Diagnostic logging and the Orb share one long-task observer. In smaller viewers the panel stays within its host and scrolls instead of clipping its contents.
- **Claude handler scheduling**: synchronous message parsing stays outside the small async coroutine. Each foreground turn awaits one completion promise instead of creating a new await chain on every idle poll. A single `later` timer processes at most 32 messages or 8 ms per normal batch, yields immediately for buffered work, and waits 50 ms for an empty queue. Approval pauses conversation dispatch, while the same owner checks controls, task events, and connection health once per second; terminal results stop the foreground timer. Late context-usage callbacks retain only the usage snapshot, not the completed turn. Cancellation, tools, history, concurrent threads, Shiny promise domains, deep-stack tracing, and R JIT retain their existing contracts.
- **Long tasks and recovery**: healthy background work and approvals are not stopped merely because two minutes elapsed. An interruption drains its terminal result before another turn can use that queue; an unconfirmed drain or disconnected CLI retires the old connection without replaying tools. Parent-agent messages do not wait for a nonexistent top-level result. Task Stop acknowledgements mean “requested”, not “stopped”; failures or missing terminal events allow retry, and disconnection is reported as an unknown outcome. Error replies can recover from authoritative history without hiding the error or overriding a cancelled/newer request. Terminal history reconciliation releases its short foreground wait and follows late writes for at most 30 seconds, including replies written after an initially user-only snapshot. Reopen history if synchronization remains unavailable. History-only browser attachments can receive newly arriving background approvals and results without sending a prompt; run-scoped events from the previous browser remain isolated. Memory admission still limits new work, but never suppresses already-running tasks' notifications.
- **Investigating R memory**: [`tests/verify/compare_sdk_memory.R`](tests/verify/compare_sdk_memory.R) compares the installed SDK alone, the production handler, a thin shinychat adapter, and the current widget in fresh processes. Run it through the bounded verifier's `browser` mode. It uses a local deterministic stream-json peer, not an AI provider, while retaining the real SDK subprocess/parser; records resident memory separately from post-GC R heap; and checks output, restored history, browser errors, and process cleanup. `AUI_MEMORY_ARMS`, `AUI_MEMORY_EVENTS`, and `AUI_MEMORY_OUT` select the experiment and evidence directory. `AUI_MEMORY_DEEPSTACK=0` is an isolated diagnostic control, not a production fix or a change to an existing addin Job. Do not use `--resume` across different environment-controlled experiments.
- **Handler regression gates**: [`verify_handler_performance.R`](tests/verify/verify_handler_performance.R) enforces resident-memory and latency bounds at 1,200/2,400 events; [`verify_foreground_pump.R`](tests/verify/verify_foreground_pump.R) adds 60/120-second slow streams, a 60-second quiet wait, and delayed/missing context-usage replies (`AUI_FOREGROUND_MODE=slow|quiet|usage`, `AUI_FOREGROUND_OUT` for evidence). [`verify_handler_protocol.R`](tests/verify/verify_handler_protocol.R) drives restored tool history, real SDK approvals, Stop, and two concurrent threads through Chromium. All use the installed production handler, default deep-stack tracing, and local synthetic CLI peers; they never execute tools or contact an AI provider. Run through the bounded verifier's `browser` mode, with `--timeout 240` for the foreground-pump gates. `AUI_MEMORY_PROFILE=1` on the comparison script records separate CPU/allocation profiles for diagnosis; profiled timings are not the performance-gate measurements.
- **Long-task regression gate**: [`verify_long_task_lifecycle.R`](tests/verify/verify_long_task_lifecycle.R) uses the installed SDK and widget with real isolated JSONL history. One Chromium instance exercises a 125-second background task, foreground/background approvals held for 125 seconds, Stop rejection/retry, parented-only completion, delayed error replies, EOF recovery, history paging during a live approval, and new approvals arriving after a full browser reload without another foreground prompt. Run with the bounded verifier's `browser --timeout 240`; `AUI_LONG_TASK_OUT` preserves evidence. `AUI_LONG_TASK_MODE=smoke` is a short fixture check, not evidence of the long-duration gate.
- **Long-history rendering**: threads with more than 60 retained messages use a measured virtual window, keeping nearby messages, the latest tail, and active editors/focused controls mounted. History paging and streaming retain their scroll anchors without keeping every message component subscribed while you type. The existing history-retention limit is unchanged. Browser Find (Ctrl+F) and cross-message text selection cover only currently mounted content; scroll to older messages to render them.
- **Independent session startup**: foreground turns use the SDK's asynchronous initialization handshake, so connecting a second history session does not freeze the first session's stream or Shiny inputs. Stop during initialization cancels only that connection, before sending a prompt; cancellation never falls back to a fresh conversation. The normal addin admits two concurrent histories (four in Workspace), while each history remains FIFO. `verify_addin_session_independence.R` checks delayed cold startup, warm streams, approval, cancellation, queued admission, and reload through the installed addin.
- Requires [`ClaudeAgentSDK`](https://github.com/kaipingyang/ClaudeAgentSDK) `>= 0.2.5.9001`
  and a working `claude` CLI. Update both packages and restart the existing addin Background
  Job: an already-running R process does not reload either package automatically.
  Runs in the browser if called outside RStudio. The CLI's own tool limits are unchanged.

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

Creates the chat placeholder for the native Shiny output binding.

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

The React component (`@assistant-ui/react`) manages all UI state internally via Zustand. R communicates via `session$sendCustomMessage()` for streaming and `input$*` for user events — the native Shiny output binding pattern.

## Development

Rebuild the JS bundle after editing `srcjs/`:

```bash
npm run build      # one-shot
npm run dev        # watch mode
```

Requires a Node version accepted by the root `engines` declaration and lockfile:
`^20.19.0 || ^22.12.0 || >=24.0.0`. Node.js is not required for package users.

## License

MIT © Kaiping Yang
