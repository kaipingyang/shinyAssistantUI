# shinyAssistantUI 0.2.0.9010 (development version)

RStudio Claude Code addin enhancements (additive; requires `ClaudeAgentSDK >= 0.2.2`
for the agentic R tool).

## "Strict" permission mode — ask before every tool

- New **Strict** option in the permission-mode selector: prompts for approval on **every**
  tool call (not just edits/risky commands), so nothing runs without your say-so. Implemented
  by injecting `{"permissions":{"ask":["*"]}}` into the session settings, which keeps the full
  approval card (permission suggestions, "Always allow …", "Deny & tell Claude…") intact —
  pair it with "Always allow" to whitelist safe tools as you go. Switching into or out of
  Strict reconnects the session (like the thinking/model controls).

## Tool card display fixes

- **Tool title** now shows a meaningful argument (file name for `Edit`/`Write`/`Read`,
  command for `Bash`, etc.) instead of whatever key happened to be first — fixes titles like
  `Edit(false)` (a leading boolean `replace_all`) now showing `Edit(app.R)`.
- **Edit diff line numbers** now reflect the **real file line numbers** instead of always
  starting at 1: the server locates `old_string` in the file and passes the start line, so
  the on-screen diff matches what you see when you open the file. (Single `Edit`; `MultiEdit`
  keeps 1-based numbering for now.)

## `assistant_tool_view()` — declare a tool's argument rendering from R

- New exported helper `assistant_tool_view(kind, field, lang, ...)` builds the `argsView`
  tool-call annotation, so **R-authored tools** (ellmer tools — forwarded automatically by
  `make_ellmer_handler()` — and any custom `handler` calling `on_tool_call(annotations = ...)`)
  can declare how their arguments render (`code` block with a language, or a `diff`) instead
  of the raw-JSON fallback. Pure metadata (no `ellmer`/`curl` dependency; `ellmer` stays in
  Suggests). Fixed built-in tools keep their client-side rules; this is the server-side
  extension point for tools whose semantics only the author knows.

## Tool cards: rich argument rendering

- Tool-call cards render their **arguments** by tool semantics instead of raw JSON:
  **Bash** → shell code block, **Write** → code block (language by file extension),
  **run_r** (`mcp__r_session__run_r`) → **R code block**, **Edit/MultiEdit** → diff,
  **TodoWrite** → a status **checklist**, and **Grep / Glob / WebSearch / WebFetch** →
  a compact **query summary** (labelled fields; URLs as links). Unknown tools keep the
  JSON fallback (no regression). Text tool **results** (e.g. `run_r` / Bash output) render
  as a monospace **console** block, not JSON.
- Extensible & decoupled: a pure `resolveToolView()` (16 unit tests) maps a tool call to a
  `ToolView` (`diff` | `code` | `todos` | `query` | `json`); a dumb `ToolArgsView` renders
  it by reusing existing diff/code/JSON components. Any MCP tool can declare its own view
  from R via `on_tool_call(annotations = list(argsView = list(kind = "code",
  field = "code", lang = "r")))` — the server-side extension point.

## Tool approval: "Always allow" + deny-with-feedback

- The approval card now surfaces Claude Code's **permission suggestions** as
  **"Always allow …"** buttons (e.g. *Always allow edits*, *Always allow this folder*,
  *Always allow Bash(git status:\*)*). Clicking one approves the call **and** adds the
  suggested permission rule / directory / mode for the session, so matching future calls
  are not re-prompted. Handler now maps `setMode` suggestions (in addition to the existing
  `addRules` / `addDirectories`).
- New **"Deny & tell Claude…"** action: reveals a text box (placeholder *"Tell Claude what
  to do differently"*, echoing Claude Code's own prompt) so a denial can carry a free-text
  reason back to Claude (via `deny_tool(message=…)`) instead of a bare refusal.
- Plain **Allow** / **Deny** remain; when the backend sends no suggestions the card is
  unchanged.

## Markdown / rendering polish

- Pinned top **"Question"** bar is now a **scroll-spy**: as you scroll up through the
  history it shows the user prompt of the turn currently in view (not always the
  latest), matching the Claude Code CLI; scrolling back to the bottom shows the
  latest prompt again.

- Unlabeled / `unknown` fenced code blocks now render (and are labelled) as
  **markdown** instead of being forced to **R** — no more mislabelling plain
  text/output as R code. (`ClaudeAgentSDK`-independent.)
- Inline `` `code` `` is now **blue** (blue text + light-blue background), matching
  the Claude Code CLI, instead of the muted gray. Applies in the addin /
  non-Bootstrap hosts; Bootstrap-based embeds still have Bootstrap's `code` style
  win (a known bslib scoping conflict — the addin uses `assistantUIPage()` which
  suppresses Bootstrap).

## New features

- **Run in Console** — R code blocks show a ▶ button that runs the snippet in your
  live R session (`.GlobalEnv`), echoing it to the console; the captured output is
  fed back to Claude automatically.
- **Agentic `run_r`** — Claude can write R and run it in your live session via an
  external stdio MCP server (`inst/mcp/run_r_server.R`, curl-free), routed over
  nanonext to the main-session env-server. Gated by the approval card; a per-session
  **"Auto-run R"** toggle can auto-approve.
- **Console echo styling** — Claude-run code is shown classic-R-console style: a cyan
  rule header, blue `> `/`+ ` prompts, `prettycode` syntax highlighting, red errors.
- **Full-width chat by default** — the conversation now fills the pane (like the CLI /
  VS Code) instead of a centered 44rem column; opt back into a fixed column with
  `assistantUIServer(thread_max_width = "44rem")`.

## Fixes

- Route `run_r` as an external **stdio** MCP server (not in-process `type="sdk"`),
  eliminating a ~55s first-message stall the CLI exhibits for in-process servers when
  the connection idles before the first message.
- env-server no longer throws `nanonext::context(): Object closed` on addin
  restart/reconnect (stale poll loop self-terminates; closed-socket poll is safe).

# shinyAssistantUI 0.2.0

Major release: migrated to the official `@assistant-ui/react` registry model and
aligned the UI with modern ClaudeAgentSDK capabilities, while keeping full v0.1.0
feature parity.

## Stack migration

- Rebuilt on **`@assistant-ui/react` 0.14.26** + **Tailwind v4** (`@tailwindcss/vite`,
  oklch `@theme` tokens), vendoring the official registry components (`Thread`,
  `ToolFallback`, `ThreadList`, composer, etc.) into `srcjs/`.
- New root uses the official `<Thread>` driven by a Shiny `ExternalStoreRuntime`; R
  still communicates via `session$sendCustomMessage()` + `input$*` (unchanged bridge
  protocol).
- Theme layer redone for Tailwind v4 tokens: `assistant_theme()` colors inject scoped
  `--primary`/etc. CSS variables (any R color format), each widget independently themed.

## New ClaudeAgentSDK-aligned features

- **RStudio addin (`claude_addin()`)** — an "Claude Code Chat" addin (Addins menu, or call
  `claude_addin()`) opens the chat in the RStudio Viewer/dialog, rooted at the current project
  so Claude's agentic tools (Read/Edit/Bash/Grep) act on your files. The active editor file +
  selection are injected as context via `SystemPromptPreset(append=)` (appended to Claude
  Code's preset, not overriding it), so you can just ask "explain this" / "refactor the
  selection". Edits/shell commands are approval-gated (`permission_mode = "default"`). Degrades
  to the browser when run outside RStudio.

- **Slash control actions** (client-side, not sent to the AI), dispatched by
  `make_claude_handler`'s auto-wired `action_handler`: `/model` (set_model),
  `/permissions` (set_permission_mode), `/context` (get_context_usage), `/compact`
  (streaming `send("/compact")` with progress), `/mcp` (get_mcp_status), `/resume`,
  `/clear`, plus `fork`/`tag`/`stoptask`. Results feed back into the action bubble.
- **Cost / usage footer** — `total_cost_usd`, tokens, turns, duration from `ResultMessage`.
- **Subagent / Task progress cards** — `TaskStarted/Progress/Notification/Updated`, with a
  per-task **Stop** button (`stop_task`).
- **Rate-limit banner**, **system status line**, and **CLI command auto-discovery**
  (`get_server_info` populates the slash palette).
- **Server-tool cards** — parses `server_tool_use` / `advisor_tool_result` (stream path),
  with a server-tool badge. (Forward-looking; dormant on backends that don't emit these.)
- **Approval card** shows `PermissionRequestMessage` `title` / `display_name` /
  `description`; permission-rule / add-directory suggestions supported.
- **Per-thread cold-start indicator** — surfaces the `claude` CLI subprocess connect on a
  thread's first message; rendered inline, cleared once connected.
- **`prewarm = FALSE`** (opt-in) — when enabled, pre-connects the initial thread's client at
  mount so its first message isn't slowed by the cold start. Off by default so app startup
  never blocks on a backend connection (the default lazy connect happens on first message).
- Tool cards restore the v0.1.0 look on top of the official `ToolFallback`:
  `toolName(arg-summary)` title, per-tool icon (`annotations.icon`), sub-agent nesting
  indent — all additive, keeping the official chrome.

## Feature parity carried over from 0.1.0

- Tool approval (side-channel), rich tool-result types (table / code / markdown / image /
  file / sandboxed HTML), native source & image message parts, artifacts side panel,
  message queue, timestamps, thread-list sidebar, modal mode, inline thread rename, slash
  command palette, and `@mention` tool discovery.

## Bug fixes

- **React #31 crash on open** when loading history containing `file_path` tools — a
  session-load `argsText` built with `jsonlite::toJSON()` (a `json`-classed value) was
  emitted by Shiny as raw JSON (an object), which `ToolFallback.Args` rendered as a React
  child. Now `as.character()`'d.
- **Sidebar "..." menu opened off-screen** under React 18 — the vendored `Button` lacked
  `forwardRef`, so radix could not measure the popover anchor. Now forwards its ref.
- **Duplicate tool cards on approval** — the streaming tool_use card (keyed by tool_use_id)
  and the permission card (keyed by request_id) did not merge. The approval path now uses
  `tool_use_id` for the card and `request_id` only for `approve_tool`/`deny_tool`.
- Tool cards render their args again and default to open (web-search etc. now show as
  proper cards, not a bare "Used tool:" line).

# shinyAssistantUI 0.1.0

- Initial release: `@assistant-ui/react` wrapped as a Shiny htmlwidget with streaming
  output, slash commands, attachments, and tool-call display; backend-agnostic
  (ClaudeAgentSDK, ellmer, or any R backend).
