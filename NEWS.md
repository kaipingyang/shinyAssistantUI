# shinyAssistantUI 0.2.2.9010 (dev branch)

## Sync-0.15 P2: react-devtools (dev-only, opt-in)

- Wired official `@assistant-ui/react-devtools@1.2.11` as a dev aid, opt-in via `?aui-devtools=1`
  URL param (or config.devtools). Off by default. NOTE: adds ~200KB to the IIFE bundle even when
  off (single-bundle can't tree-shake it) — exclude via a build define before the 0.3.0 merge.


## Sync-0.15 P2: bump @assistant-ui/react 0.15.0 -> 0.15.1 (latest)

- Bumped to `@assistant-ui/react@0.15.1` (GitHub main) — a safe patch: only mermaid/shiki
  templates + useToolCallElapsed internals changed (none of our used components differ between
  0.15.0 and 0.15.1). react-lexical 0.2.7 / react-markdown 0.14.8 dedupe cleanly (no peer
  conflict). Reference source assistant-ui-src also on 0.15.1. build + tsc 0 + 242 vitest +
  verify_markdown/tool_approval green.


## Sync-0.15 P2 (start): tool-group -> 0.15.0

- Synced `tool-group.tsx` to its 0.15.0 template (clean overwrite; no local customization).
  Fixes drift where our copy used the old `data-[state=open/closed]` Tailwind selectors while
  0.15.0 primitives emit `data-open`/`data-closed` (collapsible rotate/animate would silently
  not match). P2 continues per-component (reasoning, tool-fallback, thread-list, thread, ...).


## Sync-0.15 P1: trim unused vendored components (dev)

- Refreshed the reference source `assistant-ui-src` from 0.14.26 to `@assistant-ui/react@0.15.0`.
- Deleted 18 unused vendored official components (accordion, tabs, select, image, quote, sources,
  voice, assistant-modal/sidebar, threadlist-sidebar, directive-text, dot-matrix, flow,
  heat-graph, mermaid-diagram, message-timing, number-roll, follow-up-suggestions). They were
  imported by nothing (0 refs) and remain in the official 0.15.0 registry — re-vendor fresh when
  a feature needs them. (model-selector kept pending a keep-vs-official decision.)
  tsc 0 errors + 242 vitest + verify_markdown/askquestion green.


## Cleanup (dev)

- Deleted `AssistantUI.legacy.tsx` (2311 lines) — the pre-registry-migration UI backup, not
  imported by the build entry or any test (dead since the "vendored official Thread" migration).
- Simplified `applyEdit`/`onEdit`: dropped the vestigial `aborted` path (since applyEdit now
  always appends on a not-found parentId, it never aborted) — returns the updated array directly.


## Fix: accurate context-usage ring (dev)

- The composer context-usage ring was wrong: it used a hard-coded 200k window and summed
  input+output+cache tokens (double-counting). Now:
  - **Window is per-model**: the CLI reports the model (e.g. `claude-sonnet-4.6[1m]`); a `[1m]`
    tag → 1,000,000, else 200,000. Sent via on_usage(context_window=) and used by the ring
    (falls back to the static config only until the first usage arrives).
  - **Count = input + cache_read + cache_creation** (the disjoint input-side total = current
    context), **excluding output**. Now matches Claude Code's `/context` (e.g. 59.2k / 1.0M = 6%).
- (Also fixed another coro `x <- if(...)` that had silently broken on_usage.)


## Fix: Deny now stops the agent (dev)

- Plain **Deny** on a tool approval now interrupts the agent (`deny_tool(interrupt = TRUE)`),
  so Claude actually stops instead of continuing / repeatedly re-requesting approval via other
  tools. **Deny & tell Claude2026** (with a message) keeps `interrupt = FALSE` so Claude adjusts
  per your guidance (its purpose). Use plain Deny or Stop to halt.
- Verified end-to-end (real Claude, forced approvals): plain Deny -> 2717 Denied + no new approval
  card / no re-ask loop, file not written.


## Fixes (dev)

- **Edit -> Update no-op**: `applyEdit` used to silently drop the whole edit when the edited
  message's `parentId` was not found in the current message list (can happen in the addin after
  history load / tool-call turns due to id-scheme differences), so nothing was sent to the
  backend. It now appends the edited message and resends instead of aborting — edit always
  triggers a re-run.
- **Addin usage ring**: the RStudio addin now enables `show_usage = TRUE`, `context_window =
  200000`, `usage_style = "ring"`, so the context-usage ring shows below the composer
  (fed by make_claude_handler's on_usage). Verified end-to-end with real Claude.


## Fix: single-suggestion always-allow (dev)

- When a tool approval offers only ONE "always allow" suggestion, show it as a direct button
  (`data-approval-always-single`) instead of the dropdown + checkbox + apply flow (which is
  needless friction for a single option). Multi-suggestion still uses the dropdown.


## Component form: htmlwidget -> Shiny output binding (P1, dev)

- Migrated the mount from an htmlwidget to a native Shiny `OutputBinding` + `htmlDependency`
  (shinychat-style). `assistantUIOutput()` is now a plain `<div class="assistantUI
  assistantUI-output">` with the bundled JS/CSS attached as a dependency; `renderAssistantUI()`
  uses `shiny::createRenderFunction` to send `{inputId, config}` to the binding, which mounts
  React. All streaming/interaction still flows over sendCustomMessage / setInputValue (unchanged).
- Dropped the `htmlwidgets` dependency. KaTeX is now a local htmlDependency attached in
  `assistantUIOutput` (inert when no math renders). Verified: 242 vitest + headless
  verify_markdown/token_usage/latex/agent_state/askquestion/edit (0 console errors each).


## Official per-tool render registry (P2, dev)

- Introduced an official per-tool UI dispatch: `tool-ui/registry.tsx` maps tool names to
  `ToolCallMessagePartComponent`s at the message render site (the non-deprecated "inline tool
  render override" pattern; replaces the deprecated makeAssistantToolUI/useAssistantToolUI).
- Extracted a shared `ToolCardFrame` + `useToolCard` (chrome/args/result/approval-gating/depth/
  decision) so `ShinyToolFallback` and per-tool UIs compose it instead of one monolith.
- Migrated **AskUserQuestion** to its own registry entry (`AskUserQuestionToolUI`) as the first
  generative-ui pilot; transport unchanged (approve_tool(updated_input=answers)). Verified:
  240 vitest + headless verify_askquestion + verify_tool_approval (0 console errors).

# shinyAssistantUI 0.2.2

Stable release consolidating the 0.2.1.900x development line: upgrade to `@assistant-ui/react`
0.15.0, opt-in token-usage indicator, agent shared state (`on_state()`), LaTeX math, and the
RStudio addin enabling LaTeX by default. Highlights below.

## LaTeX math (Plan 34) — now bundled locally, no flicker

- New `assistantUIServer(latex = TRUE)` renders `$...$` (inline) and `$$...$$` (display) math
  via remark-math + rehype-katex. The RStudio Claude Code addin enables it by default (Claude
  output is often math-heavy).
- **KaTeX CSS + woff2 fonts are bundled in the package** (`inst/www/katex/`, attached via a
  local `htmlDependency` only when `latex = TRUE`) instead of a CDN — works offline and, together
  with proactive font preloading at mount, fixes the "formula resizes for a few seconds"
  (font-swap reflow) seen when opening history with many formulas.

## Edit-flow verification

- Added headless regression tests for edit-a-user-message -> Update (generic `verify_edit.R`
  and real-Claude `verify_claude_edit.R`), confirming the edited message re-triggers the backend.
  Note: in v0.15 the user action bar auto-hides the edit pencil until you hover the bubble.

## Agent shared state (Plan 36)

- Handlers can push arbitrary per-thread state to the UI via a new `on_state(list(...))`
  callback (e.g. `on_state(list(progress = i/n, current = file))` while looping over files).
  Front-end `useShinyAgentState()` subscribes; a built-in `ShinyAgentProgress` bar renders
  above the composer when `progress` is numeric. State is per-thread and session-scoped
  (STATE_SNAPSHOT-style full replacement).


## Fix

- Restore the `make_claude_handler()` export. An internal helper had been placed between
  its roxygen block and definition, so a docs regeneration reattached `@export` to the
  helper and dropped `make_claude_handler` from NAMESPACE. Moved the helper above the block.


## Token usage display (Plan 33)

- New opt-in token-usage indicator in the composer bar: `assistantUIServer(show_usage = TRUE,
  context_window = 200000, usage_style = c("ring","bar","text"))`. Renders a colour-coded ring/
  bar/text (green<65%, amber 65-85%, red>85%) with a tooltip breakdown, fed by the live
  `on_usage` token count vs the model context window. Rewired the previously-orphaned
  `context-display.tsx` off `-ui/react-ai-sdk` (a no-op under the Shiny runtime) to
  `useShinyConfig().usage`.


## Cleanup (Plan 37)

- Removed the orphaned `shiki-highlighter.tsx` (depended on the uninstalled `react-shiki`;
  incompatible with the IIFE build). Annotated `mcp-config.tsx` as an orphaned future-MCP UI.
  (The npm dependency cleanup landed with the 0.15.0 upgrade above.)


## Upgrade to @assistant-ui/react 0.15.0

- Upgraded `@assistant-ui/react` 0.14.27 → **0.15.0** (and `@assistant-ui/react-lexical` →
  0.2.7, `@assistant-ui/react-markdown` → 0.14.8, `@lexical/*` → 0.48.0 to match). Migrated the
  removed/renamed APIs: `useThreadListItem()` → `useAuiState(s => s.threadListItem.*)`;
  `aui.composer()` → `aui.composer` (property). Dropped the legacy-only deps
  `@assistant-ui/react-ui` and `@assistant-ui/react-syntax-highlighter`, and promoted native
  `react-syntax-highlighter` to a direct dependency (it was previously only transitive).
  Full test suite (240 vitest) + headless composer/approval verifies pass with 0 console errors.

# shinyAssistantUI 0.2.1

RStudio Claude Code addin enhancements (additive; requires `ClaudeAgentSDK >= 0.2.2`
for the agentic R tool).

## AskUserQuestion — interactive question card

- Claude Code's **AskUserQuestion** tool (used e.g. during planning when it needs your input)
  is now an **interactive card** instead of a silent JSON approval: each question shows its
  header + options as **radio** (single-select) or **checkboxes** (multi-select) plus a
  free-text **"Other"** box and a **Skip**. Your answers are sent back to Claude via the
  permission channel (`approve_tool(updated_input=…)`), with the exact schema reverse-engineered
  against the CLI: `answers` is a record keyed by each question's text, value = the chosen
  option label (string) or, for multi-select, an array of labels.

## History: real tool results (not "Session ended")

- When re-opening a past Claude session, tool cards now show the **actual tool result**
  (matched from the transcript's `tool_result` blocks by `tool_use_id`) instead of a
  placeholder `"Session ended"`, and carry the real **error state** — so a **denied** tool
  shows its red "User denied…" result and a **successful** one shows its output. Tool calls
  with no recorded result (session truly cut off mid-run) still fall back to `"Session ended"`.

## Permission modes: Strict first + new YOLO

- **Strict** is now the **first** option in the permission-mode selector.
- New **YOLO** mode — truly never prompts. Unlike **Bypass** (which keeps the stdio
  permission-prompt channel wired for the approval card and so can still ask, e.g. for
  out-of-working-directory access), YOLO runs with `bypassPermissions` **and drops
  `--permission-prompt-tool` entirely**, matching the CLI's `--dangerously-skip-permissions`
  (no prompt channel → nothing to ask). Switching into/out of YOLO reconnects the session.
  Use only in fully trusted environments.

## Approval card: multi-select "Always allow"

- The per-suggestion "Always allow …" buttons are now collected under a single
  **"Always allow… ▾"** control that opens a checkbox list, so you can **select several rules
  at once** (e.g. *Always allow this folder* **and** *Always allow edits*) and apply them
  together with one **"Approve & remember (N)"** click. Previously each suggestion was a
  separate single-click button, making it impossible to pick more than one. Multiple
  `PermissionUpdate`s are sent in a single `approve_tool()` call. Plain **Approve** / **Deny** /
  **Deny & tell Claude…** are unchanged.

## Tool card display

- **Edit / MultiEdit / Write** tool cards now **expand by default** so the diff / new content
  is visible without a click.
- The clickable **file-path** shown on file tools (`Read`/`Edit`/`Write`/…) is no longer
  truncated — the **full path** is displayed (wraps if long), so a collapsed card still shows
  where the change lands.

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
