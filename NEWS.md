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
