# shinyAssistantUI 0.5.1.9000 (dev branch)

- **Write Markdown table layout (Plan 61)**: Markdown tables shown in expanded `Write`
  tool arguments now keep each source row intact instead of placing every pipe and cell on its
  own line. Prism token spans are locally isolated from same-named Tailwind layout utilities
  (notably `.table`), preserving syntax highlighting in both live and restored tool cards.

- **AskUserQuestion custom answers + readable card (Plan 60)**: selecting a preset and then
  typing an **Other** answer now correctly submits the custom text instead of the stale preset.
  Other is an explicit radio/checkbox: single-choice answers are mutually exclusive, while
  multi-choice answers may combine presets with custom text. The tool's expanded arguments now
  show readable questions, Single/Multiple choice badges, and option descriptions instead of raw
  `questions` JSON; malformed payloads still fall back to JSON for debugging.

# shinyAssistantUI 0.5.1

- **文件引用点击打开 / file-reference opening (Plan 58)**: bare filenames in assistant prose
  such as `dm.R` now resolve to the most recent matching `file_path`/`path` from the current
  thread's tool calls, so a file under `<cwd>/subfolder/` opens without a filesystem scan.
  A read-only fallback may reuse an already-hot `@mention` workspace index, but clicking never
  builds a cold index; cold, missing, ambiguous, or stale matches stay silent. Per-click RStudio
  API calls drop from three to two by reusing the addin's startup availability check, while the
  current-editor guard remains. Markdown chips and tool-card links immediately show English
  **Opening…** feedback during IDE/network latency.

- **修复:切换工作目录卡顿 (Plan 57)**: switching the working directory (or model / permission
  mode / thinking / autorun / run_r) no longer freezes the addin for ~10s. The old CLI clients'
  teardown (each `interrupt`+`wait`+`kill`+`wait`, up to ~5s per subprocess) ran synchronously on
  the R event loop; it's now deferred to `later` — the client registry is cleared synchronously
  (so the new directory reconnects cleanly) while the old subprocesses are disconnected in the
  background. Click → refresh is now immediate. Session-end teardown stays synchronous.

- **上传 PDF 与 Excel / PDF & Excel upload (Plan 56)**: attach or drag-drop a **PDF** — it's sent
  to Claude as a native **document block**, so Claude reads its text *and* visuals (no server-side
  parsing, no poppler) — or an **Excel** `.xlsx/.xls`, parsed server-side with `readxl` into a
  markdown table (per sheet, row/col-capped; backend-agnostic). Text files
  (`.md/.csv/.txt/.json/…`) already worked. New `FileAttachmentAdapter` base64-encodes files with
  **no client-side parsing** (bundle unchanged); `readxl`/`writexl` added to Suggests. Word/PPT are
  intentionally deferred (poor ROI — see Plan 56).
- **动态 follow-up 建议 / dynamic suggestions (Plan 48B)**: handlers can push "next step" chips
  at any time via the new `on_suggestions(list(...))` callback (strings or `list(prompt=, text=)`);
  they render as clickable chips **below the latest reply** (not just the welcome screen) once the
  turn finishes, and clicking one sends it immediately. Cleared automatically at the next user turn.
  New `:suggestions` channel + `ThreadFollowupSuggestions` (reads `thread.suggestions`).
- **划词引用 / Quote (Plan 48A)**: select text in an assistant reply and a floating **Quote**
  toolbar appears; clicking it quotes that text into the composer (shown as a preview). Your
  follow-up is sent in the **same conversation** with the quoted text prepended as a markdown
  blockquote, so the model has focused context — no manual copy-paste, no new session. Built on
  `@assistant-ui/react` primitives (`SelectionToolbar` / `ComposerQuotePreview` / `QuoteBlock`);
  the quote rides at `message.metadata.custom.quote` and is injected backend-agnostically
  (Claude / ellmer / codeagent) via a blockquote prefix.

# shinyAssistantUI 0.5.0

## codeagent backend

- **Out-of-process backend (Plan 52 A/B)**: `make_codeagent_remote_handler()` runs codeagent in a
  separate R worker process pinned to a new-curl library, so the MAIN Shiny process never loads
  codeagent/ellmer/curl (safe inside sessions with a legacy `curl`, e.g. ERP). Streaming + tool
  display + the permission approval card are marshaled over a socket; approve/deny works across the
  process boundary and the worker is torn down on session end. `callr` added to Suggests.
- **Permission bridge (Plan 51 Phase B)**: `make_codeagent_handler(permission_mode=)` now bridges
  codeagent's central permission gate to the in-app approval card — sensitive tools (write/execute)
  prompt for Approve/Deny while reads auto-allow. Approve/deny only (the gate cannot rewrite tool
  input). `examples/27` switched from `bypass` to `default`.

## Composer

- **Slash-command argument hints**: the slash menu shows argument hints (e.g. `/skill [arg]`), and
  after selecting a command an inline ghost hint appears in the composer (rendered via a safe CSS
  `::after`, so nothing is injected into the editable value).
- **Trailing space after slash-command completion**: completing a skill/command inserts a trailing
  space so you can type the argument immediately and Enter sends. Deterministic actions
  (`/clear`, `/compact`, …) are not affected.

## Attachments / images

- **Paste & drag-drop images** into the composer as attachments (Ctrl/Cmd+V or drop).
- **Image attachments are downscaled** (max ~1280px edge, kept well under the CLI's stdin line
  limit) so large screenshots no longer hang the `claude` CLI.
- **Image-only messages fixed** (message with an image and no text): previously it crashed
  (`ClaudeSDKClient` has no `send_with_images()`), deadlocked on an empty text content block,
  showed an empty text bubble, and was silently dropped by the submit guard (no cold-start, no
  reply). All fixed — image-only sends omit the empty text block and still reach the handler.
- Text-file attachments continue to inline their content into the outgoing message.

# shinyAssistantUI 0.4.0

## Generative UI (Plan 47) — all opt-in, no new hard dependencies

- **R-driven Data UI**: `on_data_ui(name, data)` streams a `data-<name>` message part rendered by a
  small in-repo component table (`table` / `stat` / `flow`) — analysis results (tables, metrics,
  flow diagrams) appear inline in the conversation. The previously-orphaned `FlowCanvas` is now a
  real `flow` component.
- **Generative-UI primitive**: `on_generative_ui(spec)` renders a `{root:{component,props,children}}`
  layout via `MessagePrimitive.GenerativeUI` against a consumer component allowlist (the security
  boundary). Uses `@assistant-ui/react` core — no extra dependency.
- **Interactive parameter form**: a `PromptUser` tool UI (radio/select/slider/text/checkbox) collects
  input and returns it via a new generic `updated_input` approval-transport path.
- **Artifact panel real rendering**: markdown artifacts now render as Markdown (headings/tables/
  lists/highlighted code) and code artifacts are syntax-highlighted (honoring `lang`) — previously
  raw `<pre>`.
- **`plot_data_uri(expr, width, height, res)`**: capture a base/ggplot2/lattice plot to a PNG
  `data:` URI for `on_image()`, so charts show inline via R's own plotting.

## codeagent backend (Plan 51, phase A)

- **`make_codeagent_handler(client_factory, ...)`**: drive the chat with a full
  [codeagent](https://github.com/kaipingyang/codeagent) agent (harness: self-heal, compaction,
  skills/hooks, tools) instead of a bare ellmer chat. `codeagent` is a **Suggests** (guarded) — it is
  never loaded unless you opt into this backend, so the Claude addin / bare install stay lean. Phase A
  = streaming + typed tool-display forwarding + background client pre-warm (no white-screen cold start);
  permission gating is a follow-up.

## Fixes

- **Real-time auto-scroll**: the viewport lagged 200–2000px behind during rapid streaming (tool
  chains / approvals not visible in real time) because `content-visibility:auto` +
  `contain-intrinsic-size` on message roots corrupted `scrollHeight`, which the built-in autoScroll
  depends on. Removed that CSS — the viewport now tracks the bottom in real time.
- **`assistant_theme()` doc-contract crash**: the roxygen falsely promised HSL-component output +
  bare-`"217 91% 60%"` passthrough; corrected to match actual behavior, and `.color_to_css()` now
  errors clearly (pointing at `hsl(...)`) instead of a cryptic `col2rgb` crash.
- **Session-load crash** on JSONL lines lacking a `type` field (`NULL == "user"` → length-zero error);
  now uses `identical()` on both branches.

## Config

- **`warming_label`** and **`welcome_message`** (`assistantUIServer()`): backend-agnostic English
  defaults ("Starting…" / "How can I help you today?"), overridable per app.

# shinyAssistantUI 0.3.1

## Bug fixes

- **Context-usage ring now reflects current context occupancy, not cumulative
  throughput.** The ring previously summed `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` from each turn's `ResultMessage`, but cache reads accumulate
  across a turn's tool iterations (~3×) — so the ring could read ~92% while `/context` reported
  ~31% for the same session. It now reads the same source as `/context`
  (`ClaudeSDKClient$get_context_usage()`), shows the true current occupancy against the model's
  real window (`rawMaxTokens`), and refreshes silently *after* the turn completes (deferred via
  `later`, so it never delays "done" or blocks typing). When `get_context_usage()` is
  unavailable, the ring shows nothing rather than a misleading fallback number. The cost/usage
  footer continues to show cumulative tokens (that metric is intentionally cumulative).

# shinyAssistantUI 0.3.0

A large release consolidating the 0.2.2.900x development line.

## Foundation

- **Migrated the vendored UI layer from radix-ui to base-ui** and aligned to
  `@assistant-ui/react` 0.15.1. The source tree is radix-free (radix-ui remains only a transitive
  dependency of `@assistant-ui/react`'s own primitives).
- **Removed the `htmlwidgets` dependency**: the widget now registers as a native Shiny output
  binding (`assistantUIOutput()` + `renderAssistantUI()` sending `{inputId, config}`). KaTeX is
  bundled locally (no CDN font reflow).

## Permissions & Settings (addin)

- **Two-tier permission-mode switching**: de-escalation (to a stricter mode) hot-switches instantly;
  escalation (to a more permissive mode) and the pseudo modes (Strict/YOLO) reconnect so the mode is
  applied at connect (runtime escalation is not honored by the CLI).
- **Settings panel repurposed** to persistent preferences: new-conversation default mode + risky-mode
  visibility (hide Bypass/YOLO), instead of duplicating the composer's live mode switch.
- UI preferences now live in a single human-readable `~/.claude_addin/addin_settings.json`
  (migrated once from the old per-preference `.rds` files).

## Composer & UX

- **Composer height preset** (Comfortable default / Compact flat single-row inline, ~shinychat).
- Official `@assistant-ui` ModelSelector inline in the composer.
- Approval cards auto-scroll into view during continuous approvals; large tool cards follow the
  viewport (0.15.1 message containment).
- Switching the working directory reloads that project's local skills/commands (slash menu hot-update).
- `run_r` MCP tool can be toggled off in Settings.

## Fixes

- Run-in-console now captures `cat()`/`print()` stdout (was "(no visible output)").
- Delete-confirmation dialog dismisses immediately on confirm.
- History sessions restore per-tool approval/deny state; deleting a session prunes its decisions.
- Devtools excluded from the production bundle (smaller build).

Internal: `R CMD check` clean (0 error/warning/note).

# shinyAssistantUI 0.2.2.9022 (dev branch)

- Compact composer: input is now first (far-left, flex-1) with controls on the right, so the caret
  starts at the far left (was pushed to center by the left-side controls).


- Compact composer keeps all controls (attachment, permission mode, model selector, usage ring) inline
  on the single flat row (earlier they were dropped/moved).
- Approval cards now auto-scroll into view when they appear during continuous approvals (the turn is
  suspended so assistant-ui's stream auto-scroll did not fire).


- addin UI preferences (default permission mode, mode visibility, composer height, run_r toggle) are
  now stored in a single human-readable ~/.claude_addin/addin_settings.json (was 4 separate .rds).
  Old .rds prefs are migrated once on startup and removed (transparent for existing users). Data files
  (session_map, archived, tool_decisions, ...) stay RDS.
- Deleting a history session now also prunes that session's tool-approval decisions (no orphan
  entries accumulating in tool_decisions.rds).


- Switching working directory now reloads that project's local skills/commands and hot-updates the
  slash menu (previously skills were read once at startup, so a switched-to project's .claude skills
  were not picked up). New ctrl$send_commands() + :commands message path.

# shinyAssistantUI 0.2.2.9018 (dev branch)

## Bug fixes & compact flat composer

- New-conversation default mode now reflected on new chats (composer fell back to the static
  page-load value; now uses the live default; unswitched threads follow the current default).
- Delete-confirmation dialog now dismisses immediately on "Delete permanently" (was staying open
  until an outside click, because the delete is async).
- Auto-scroll during tool calls fixed: backported 0.15.1 message containment (contain-intrinsic-size
  auto_24px->auto_200px moved to the message root), so large tool cards/approval boxes below the fold
  are measured correctly and the viewport follows them.
- Compact composer height is now a genuinely flat single-row inline layout (input + send on one row,
  ~shinychat), ~40%% shorter than Comfortable.


## Settings & permission-mode UX (Plan 45)

- Permission-mode switching is now two-tier: de-escalation (to a stricter mode) hot-switches
  instantly; escalation (to a more permissive mode) and the pseudo modes (Strict/YOLO) reconnect so
  the mode is applied at connect (runtime escalation is not honored by the CLI). Safe by construction.
- Settings panel repurposed (no longer duplicates the composer's live mode switch): new-conversation
  default mode + risky-mode visibility (hide Bypass/YOLO), both persisted.
- Composer height preset (Comfortable default / Compact flat single-line, ~shinychat); auto-grow kept.
- run_r MCP tool can be toggled off in Settings (drops it from the connection on reconnect).
- All new prefs persist under ~/.claude_addin/.


## Bug fix

- **Switching permission mode to Bypass (or Auto-edit) had no effect on the live session** — it kept
  prompting for every tool. Cause: real-mode switches used the runtime `set_permission_mode` control
  request, but Claude Code will not hot-*escalate* to a more permissive mode mid-session (accepted
  but not applied). Fix: permission-mode changes now `reset_clients()` so the next message reconnects
  with the mode applied at connect time (`--permission-mode`), which is always honored — same as the
  askAll/yolo/thinking paths. Verified with a real CLI test (`verify_permission_mode.R`): default
  prompts for Bash, bypassPermissions does not. Note: switching disconnects the current client, so
  if you switch while an approval card is pending, resend the message.

# shinyAssistantUI 0.2.2.9015 (dev branch)

## UX

- Moved the ModelSelector into the composer bottom action row (next to the permission-mode
  selector), instead of above the composer. /model still opens it (controlled popover).

# shinyAssistantUI 0.2.2.9014 (dev branch)

## Bug fixes (real-machine feedback)

- **Run-in-console captured no output**: `.addin_run_r_capture` only returned the visible value, so
  `cat()`/`print()` output (which goes to stdout) was lost — Claude saw "(no visible output)" and
  retried, appearing one step behind. Now wraps eval in `capture.output()` (via an env box to avoid
  `<<-` scoping) so stdout, the visible value, messages and warnings are all captured.
- **Run-in-console separator too long**: the `── Claude ran in console ──` header used `cli::rule`,
  which spans the full console width. Now a fixed-width cyan separator.
- **History session lost approval/deny state**: tool cards showed "✓ Approved / ✕ Denied" live but
  not after reopening a session. Decisions are now persisted server-side (`tool_decisions.rds`,
  keyed by the CLI tool_use id which is stable across reloads), re-emitted by
  `.claude_msgs_to_thread` as `artifact.approvalResult`, and read back by `useToolCard`. Verified
  headlessly (`verify_session_decisions.R`).

# shinyAssistantUI 0.2.2.9013 (dev branch)

## Source is now radix-free (matches upstream 0.15.1 ui/ layer)

- Migrated the last live radix import: thread-list delete-confirmation AlertDialog -> base-ui Dialog.
- Removed 27 unused leftover shadcn scaffold files (accordion/tabs/select/menubar/dropdown-menu/
  context-menu/hover-card/checkbox/slider/switch/progress/scroll-area/radio-group/toggle/
  toggle-group/combobox/textarea/input-group/aspect-ratio/breadcrumb/button-group/form/item/
  navigation-menu/alert-dialog/direction + assistant-ui/badge) that upstream 0.15.1 does not ship
  and nothing referenced. No srcjs file imports "radix-ui" anymore.
- radix-ui stays a dependency because @assistant-ui/react 0.15.1 uses it internally for its own
  primitives (ActionBarMore/ThreadListItemMore/AssistantModal/Composer) - matches upstream.


## Follow-ups: devtools prod-exclusion, official ModelSelector, upstream-delta review

- devtools excluded from the prod bundle via `__AUI_DEVTOOLS__` build define (default off; -201KB).
- Adopted official `@assistant-ui` ModelSelector (base-ui) in place of the custom ModelPickerDialog
  (inline combobox trigger, controlled by /model). Needs real-machine UX review.
- Reviewed every heavy component's upstream 0.14.26->0.15.1 delta: markdown-text unchanged; fixed
  context-display to the base-ui tooltip (asChild->render + TooltipProvider); thread/thread-list/
  diff-viewer/syntax-highlighter deltas are minor CSS/perf/optional-feature/alternative-impl and
  their asChild usages are on assistant-ui npm primitives (still supported) — deferred as low-value.


## radix -> base-ui foundation migration (Plan 44, dev)

- Migrated the vendored UI primitives from radix-ui to **base-ui** (-ui/react), tracking
  assistant-ui 0.15.x: tooltip, collapsible, button, dialog, avatar, badge, separator, label,
  input, skeleton. Synced the assistant-ui components that depend on them (tooltip-icon-button,
  tool-group, tool-fallback, reasoning, attachment) to their 0.15.1 templates.
- Fixes real drift: the `asChild`->`render` prop change (restored data-*/onClick forwarding, e.g.
  the Run-in-Console button) and `data-[state=open/closed]`->`data-open/closed` (restored
  collapsible/arrow animations). Trimmed orphan primitives/components (model-selector, mcp-config,
  flow-expand, sidebar, command, popover, sheet).
- Verified: tsc 0 + 242 vitest + 26/26 example gallery + verify_markdown/token_usage/tool_approval/
  tool_card_fixes/askquestion/latex/agent_state/edit/strict_mode (0 console errors). thread/
  thread-list/markdown-text/context-display already correct on base-ui (data-attrs match 0.15.1);
  full template re-sync of those heavy-custom components deferred (high-risk, low-value).


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
