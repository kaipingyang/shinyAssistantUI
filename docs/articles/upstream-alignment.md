# Upstream documentation alignment

## Purpose and review rules

This ledger reviews the assistant-ui documentation in the visible
sidebar order defined by the upstream `meta.json` files. It translates
relevant concepts to the public R/Shiny package boundary and prevents a
React component, similarly named feature, or generic backend callback
from being mistaken for a complete integration.

**Reviewed:** 2026-09-10 against the current upstream navigation and the
package source using `@assistant-ui/react` 0.15.17.

Statuses have strict meanings:

  - **Adopted** — the upstream behavior is present end to end.
  - **Adapted** — the user need is met through a deliberate
    R/Shiny-specific contract.
  - **Partial** — useful pieces exist, but a required behavior, public
    extension point, or backend semantic is missing.
  - **Future plan** — the capability is intentionally visible on the
    roadmap but is not supported now.
  - **Not adopted** — an upstream integration exists, but this package
    has not implemented it.
  - **Not applicable** — a different platform or ecosystem does not
    belong in this browser-based Shiny package.
  - **Maintainer-only** — relevant to the bundled React implementation,
    not an R user API.

Three rules apply throughout:

1.  A generic R handler can call many services, but that does not create
    a first-party adapter for AI SDK, LangGraph, LangChain, AG-UI, A2A,
    or another protocol.
2.  A visible component is not proof of complete semantics. For example,
    the current edit and reload paths truncate a linear message array; a
    hidden `BranchPicker` does not preserve alternative branches by
    itself.
3.  Public documentation describes portable package contracts only.
    Worker provisioning, library location, authentication, and
    deployment topology remain deployment-specific.

## Selected architecture

``` text
assistant-ui React Web components
  -> custom ExternalStoreRuntime adapter
  -> Shiny inputs and custom messages
  -> assistantUIServer() R callback contract
  -> ellmer, ClaudeAgentSDK, codeagent, or application-owned R code
```

The package does **not** use `LocalRuntime`, the assistant-ui Data
Stream protocol, or Assistant Transport. It uses a native Shiny output
binding and an `htmlDependency()` to ship the compiled web surface.
Client, server, or disabled persistence is owned by the package and
application, not by Assistant Cloud.

## Ordered family status

| Sidebar order | Family                  | Overall result                                                                                  |
| ------------: | ----------------------- | ----------------------------------------------------------------------------------------------- |
|             1 | Getting Started         | R installation and architecture adapted; RTL partial; CLI user workflow not applicable          |
|             2 | Guides                  | Core chat guides mixed: several adopted, several partial, resilience/voice gaps explicit        |
|             3 | Tools                   | Shiny-native tool UI adopted; Toolkit/MCP browser ecosystems not adopted; A2UI is a future plan |
|             4 | Primitives              | Most primitives used internally; public API remains R-level                                     |
|             5 | Components              | Main thread/composer/tool components adopted; optional add-ons reviewed individually            |
|             6 | Runtimes                | ExternalStore adopted; all named framework/protocol runtimes remain unadopted                   |
|             7 | Integrations            | R-native alternatives exist for some needs; no automatic JavaScript ecosystem adapters          |
|             8 | React Native            | Not applicable                                                                                  |
|             9 | Ink                     | Not applicable                                                                                  |
|            10 | Cloud                   | Not adopted                                                                                     |
|            11 | Utilities               | Optional or not applicable                                                                      |
|            12 | Migrations              | Maintainer-only                                                                                 |
|            13 | Copilots (experimental) | Related product ideas, but no public API compatibility                                          |
|            14 | API Reference           | Internal React implementation map; not converted into R exports                                 |

## Getting Started

| Order | Official page        | Status                  | R/Shiny decision                                                                                                                                                                  |
| ----: | -------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Documentation        | Adapted                 | The local [Overview](https://kaipingyang.github.io/shinyAssistantUI/articles/shiny-assistant-ui.md) starts with a Shiny app and R handler rather than a React scaffold.           |
|     2 | Installation         | Adapted                 | The [Installation guide](https://kaipingyang.github.io/shinyAssistantUI/articles/installation.md) installs an R package with bundled assets; npm and shadcn are contributor-only. |
|     3 | Agent Skills         | Adapted, distinct       | `load_claude_skills()` discovers Claude Code skills/commands for the addin menu. It does not install the upstream `assistant-ui/skills` authoring skills or docs MCP server.      |
|     4 | CLI                  | Not applicable to users | `assistant-ui init/create/add` target JavaScript source projects. R users call package functions; maintainers use the locked npm/Vite build.                                      |
|     5 | Architecture         | Adapted                 | UI, runtime, R backend, and persistence remain separate layers; Assistant Cloud is not part of the selected stack.                                                                |
|     6 | RTL Support          | Partial                 | Logical CSS utilities and some RTL transforms exist, but there is no public R `dir` option, direction-provider contract, or complete browser RTL gate.                            |
|     7 | Radix UI and Base UI | Maintainer-only         | Component flavor and migration are bundled implementation choices. R users do not configure a shadcn registry.                                                                    |
|     8 | DevTools             | Maintainer-only         | The upstream modal exists only in a special development bundle built with `AUI_DEVTOOLS=1`; it is absent from ordinary package builds.                                            |

## Guides

### Composer

| Order | Official page            | Status          | R/Shiny decision                                                                                                                                                                                                |
| ----: | ------------------------ | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Guides overview          | Adapted         | This ledger, the Overview, examples, and R reference replace React recipe navigation.                                                                                                                           |
|     2 | File Attachments         | Adapted         | Composer add/drop/paste, previews, R payloads, and supported backend conversions work; the package does not expose every upstream JavaScript `AttachmentAdapter` extension point.                               |
|     3 | Mentions in Chat         | Partial         | Workspace file/folder mentions and IDE context work in the addin. They remain literal backend text and are not the upstream general directive/tool/document protocol.                                           |
|     4 | Slash Commands           | Adapted         | R-configured commands, Claude Code commands/skills, and deterministic local actions share the slash menu. Exact controls are dispatched on submit rather than through the upstream selection-time Action model. |
|     5 | Input History            | Not adopted     | Thread history exists, but ArrowUp/ArrowDown composer recall with draft preservation does not.                                                                                                                  |
|     6 | Headless Composer Input  | Maintainer-only | The package owns a Lexical composer internally; it does not expose `unstable_useComposerInput` as a public R extension point.                                                                                   |
|     7 | Quote Selected Text      | Adopted         | Selection toolbar, quote preview, message metadata, Shiny transport, and backend prompt injection are connected end to end.                                                                                     |
|     8 | Speech-to-Text Dictation | Adapted         | Browser Web Speech dictation is wired when supported. No R server-side STT adapter contract is exposed.                                                                                                         |

### Messages and display

| Order | Official page                | Status      | R/Shiny decision                                                                                                                                                              |
| ----: | ---------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|     9 | Suggested Prompts            | Adopted     | Static starter prompts plus `on_done(suggestions=)` and `on_suggestions()` follow-ups are supported.                                                                          |
|    10 | Message Editing              | Partial     | The UI edits and re-submits a user turn after atomically truncating later local messages. Generic persistent backends are not rewound to an earlier checkpoint automatically. |
|    11 | Message Branching            | Partial     | Edit/reload and a BranchPicker component exist, but old alternatives are not retained in the package’s linear message array; switchable branch history is not complete.       |
|    12 | Message Timing & Token Stats | Not adopted | Optional timestamps and run-level usage are not TTFT, token rate, chunk count, and per-message generation timing.                                                             |
|    13 | Image Generation             | Adapted     | `on_image()` renders a backend-produced image part. Selecting an image model, generation lifecycle, and regeneration remain application/backend responsibilities.             |
|    14 | Chain of Thought UI          | Adopted     | `on_thinking()` streams reasoning; grouped reasoning and tool calls render in collapsible UI.                                                                                 |
|    15 | LaTeX in Chat Messages       | Adopted     | Optional KaTeX with local assets, math normalization, and streaming Markdown rendering is implemented.                                                                        |
|    16 | Thread Virtualization        | Not adopted | Long transcripts are not virtualized with the upstream virtual-message APIs.                                                                                                  |

### Audio, programmatic APIs, environments, and resilience

| Order | Official page                  | Status          | R/Shiny decision                                                                                                             |
| ----: | ------------------------------ | --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
|    17 | Realtime Voice Chat            | Not adopted     | Dictation is not a bidirectional realtime voice session with connect, mute, audio streaming, and interruption.               |
|    18 | Text-to-Speech                 | Partial         | A browser speech adapter can be configured internally, but the current fixed action bar exposes no Speak/Stop control.       |
|    19 | Assistant Context API          | Maintainer-only | React state/context hooks are used inside the compiled widget; they are not public R hooks or component slots.               |
|    20 | ChatGPT Subscription           | Not adopted     | Codex OAuth and the upstream local proxy are not package integrations.                                                       |
|    21 | Electron                       | Not adopted     | A browser surface can theoretically be hosted by Electron, but secure preload/IPC and packaged-app integration are absent.   |
|    22 | Resumable Streams              | Not adopted     | Stored completed history and reconnecting Shiny sessions do not resume an in-flight byte stream.                             |
|    23 | Custom Resumable Stream Stores | Not adopted     | No resumable-stream cursor/store interface or producer ownership protocol exists.                                            |
|    24 | Resumable Stream Deployment    | Not adopted     | Tenant keys, TTL, serverless lifetime, observability, and recovery controls for resumable streams are therefore also absent. |

## Tools

| Order | Official page            | Status                | R/Shiny decision                                                                                                                                                                                                                                                                                                 |
| ----: | ------------------------ | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Tools overview           | Adapted               | R callbacks and handler factories replace the JavaScript Toolkit authoring model.                                                                                                                                                                                                                                |
|     2 | Defining Tools           | Adapted               | Backends define tools in their own R APIs and emit `on_tool_call()` events; no `defineToolkit()` or `"use generative"` compiler API is exposed.                                                                                                                                                                  |
|     3 | Backend Tools            | Adapted               | ellmer, ClaudeAgentSDK, codeagent, and custom R handlers execute backend tools without a Vercel AI SDK route.                                                                                                                                                                                                    |
|     4 | Dynamic Tools            | Not adopted           | The package does not expose React-state closures through `stubTool()`/tool overrides.                                                                                                                                                                                                                            |
|     5 | Tool UI                  | Adopted               | Streaming arguments, fallback cards, dedicated views, results/errors, lazy history, and human approval are connected through Shiny.                                                                                                                                                                              |
|     6 | Generative UI            | Partial               | A local display allowlist and interactive `PromptUser` UI exist, but the package does not expose the upstream `JSONGenerativeUI` Toolkit, default vocabulary, or action registry.                                                                                                                                |
|     7 | Generative UI on Slack   | Not applicable        | No Slack Block Kit conversion or bot action decoder is part of the package.                                                                                                                                                                                                                                      |
|     8 | Generative UI on Teams   | Not applicable        | No Adaptive Card conversion or Teams bot action decoder is part of the package.                                                                                                                                                                                                                                  |
|     9 | Generative UI primitive  | Adopted               | `on_generative_ui(spec)` renders a JSON layout through `MessagePrimitive.GenerativeUI` and a fixed display-only allowlist.                                                                                                                                                                                       |
|    10 | Interactable Tool UIs    | Not adopted           | Artifact/data views are not versioned model-editable state with companion tools.                                                                                                                                                                                                                                 |
|    11 | A2UI over AG-UI          | **Future plan**       | The [A2UI over Shiny future contract](https://kaipingyang.github.io/shinyAssistantUI/articles/a2ui-shiny-contract.md) evaluates an optional surface-operation converter and action bridge while retaining the Shiny transport and current Data/Generative UI paths. No current A2UI or AG-UI support is claimed. |
|    12 | OpenUI                   | Not adopted           | No OpenUI Lang renderer or transport dependency is bundled.                                                                                                                                                                                                                                                      |
|    13 | Model Context Protocol   | Partial, backend-only | Selected backends may expose MCP tools, which render as ordinary tool calls. The browser package has no general MCP client/toolkit.                                                                                                                                                                              |
|    14 | User-managed MCP servers | Not adopted           | Browser-managed servers, connector UI, OAuth, and storage are absent.                                                                                                                                                                                                                                            |
|    15 | MCP Apps                 | Not adopted           | Sandboxed HTML results are not MCP resources and do not implement the MCP Apps JSON-RPC host bridge.                                                                                                                                                                                                             |
|    16 | Multi-Agent Chat UI      | Partial               | Task/subagent cards and nested tool depth exist, but recursive read-only sub-conversations in tool parts are not implemented.                                                                                                                                                                                    |

## Primitives

These React primitives are implementation building blocks, not
standalone R exports.

| Order | Official page    | Status inside the widget                                                      |
| ----: | ---------------- | ----------------------------------------------------------------------------- |
|     1 | Overview         | Maintainer-only mapping to the integrated R widget                            |
|     2 | Composer         | Adopted                                                                       |
|     3 | Thread           | Adopted                                                                       |
|     4 | Message          | Adopted                                                                       |
|     5 | ActionBar        | Adapted; copy/reload/edit/feedback/export are used, speech actions are absent |
|     6 | BranchPicker     | Partial; component present, persistent alternative branches absent            |
|     7 | ThreadList       | Adapted for client/server package persistence                                 |
|     8 | AssistantModal   | Adopted through `modal = TRUE`                                                |
|     9 | Attachment       | Adopted within the package’s supported attachment types                       |
|    10 | Suggestion       | Adopted                                                                       |
|    11 | SelectionToolbar | Adopted for quoting                                                           |
|    12 | Error            | Adopted                                                                       |
|    13 | ChainOfThought   | Adopted through current grouped-parts APIs                                    |

## Components

| Order | Official page            | Status      | R/Shiny decision                                                                                                                  |
| ----: | ------------------------ | ----------- | --------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Thread                   | Adopted     | Main integrated chat surface.                                                                                                     |
|     2 | Assistant Modal          | Adopted     | Public `modal = TRUE` mode.                                                                                                       |
|     3 | Assistant Sidebar        | Not adopted | The local sidebar is thread navigation/settings, not the upstream resizable chat-side-panel composition.                          |
|     4 | Attachment               | Adopted     | Composer and user-message attachment UI.                                                                                          |
|     5 | Composer Trigger Popover | Adapted     | Slash commands and workspace mentions.                                                                                            |
|     6 | Context Display          | Adapted     | R usage callbacks drive ring/bar/text context views.                                                                              |
|     7 | Directive Text           | Partial     | Directive chips exist in the composer; sent-message directives are not rendered through the upstream general directive component. |
|     8 | Custom Scrollbar         | Not adopted | Standard browser overflow is used.                                                                                                |
|     9 | File                     | Partial     | Files appear as attachments or downloadable tool results; a general file message-part renderer is not wired.                      |
|    10 | Follow-up Suggestions    | Adopted     | R callbacks update per-thread suggestions.                                                                                        |
|    11 | Image                    | Partial     | Inline images render, without the full upstream loading/fullscreen/action composition.                                            |
|    12 | Markdown Text            | Adopted     | GFM, links, tables, code, optional math, and safe rendering.                                                                      |
|    13 | MCP Config               | Not adopted | No browser MCP manager/config dialog.                                                                                             |
|    14 | Mermaid Diagram          | Not adopted | Data UI flow diagrams are not Mermaid parsing/rendering.                                                                          |
|    15 | Model Selector           | Adapted     | Capability-driven model choices and backend acknowledgement are supported where a handler advertises them.                        |
|    16 | Quote                    | Adopted     | Selection, preview, transport, and display.                                                                                       |
|    17 | Reasoning                | Adopted     | Streaming and grouped collapsible reasoning.                                                                                      |
|    18 | Sources                  | Partial     | `on_source()` creates safe clickable citation pills, not the complete favicon/document-source component family.                   |
|    19 | Streamdown               | Not adopted | The package uses its existing React Markdown pipeline.                                                                            |
|    20 | Syntax Highlighting      | Adopted     | A bounded Prism language set includes R and common tool languages.                                                                |
|    21 | Thread List              | Adapted     | Create, switch, rename, archive, delete, load, and persistence are Shiny-specific.                                                |
|    22 | Tool Fallback            | Adapted     | Shiny tool cards provide status, arguments, results, errors, approval, and lazy results.                                          |
|    23 | Tool Group               | Adopted     | Consecutive tool parts can be grouped through current grouped-parts APIs.                                                         |
|    24 | Voice                    | Partial     | Dictation only; no realtime voice session UI.                                                                                     |
|    25 | Message Timing           | Not adopted | Timestamps/tool durations do not satisfy the upstream metrics contract.                                                           |
|    26 | Message Part Grouping    | Adopted     | Current `MessagePrimitive.GroupedParts` is used for reasoning and tool groups.                                                    |

## Runtimes

### Runtime concepts and custom backends

| Order | Official page           | Status          | R/Shiny decision                                                                                                                   |
| ----: | ----------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Picking a runtime       | Adapted         | The package has already selected ExternalStoreRuntime plus Shiny transport.                                                        |
|   2.1 | Runtime architecture    | Adopted concept | UI, runtime, transport, backend, and persistence ownership are documented separately.                                              |
|   2.2 | Adapters                | Partial         | Attachments, speech, feedback, history, and suggestions have local equivalents, but not every upstream adapter contract is public. |
|   2.3 | Threads                 | Adapted         | Package-owned client/server/none persistence replaces Cloud/RemoteThreadList patterns.                                             |
|   2.4 | Stability               | Maintainer-only | Upstream experimental/stable labels guide dependency upgrades.                                                                     |
|   3.1 | Custom Runtime overview | Adapted         | Only the ExternalStore route is selected.                                                                                          |
|   3.2 | LocalRuntime            | Not adopted     | An R callback is not a JavaScript `ChatModelAdapter`.                                                                              |
|   3.3 | ExternalStoreRuntime    | Adopted         | The package owns message/thread/run state and provides edit/reload/new-message callbacks.                                          |
|   3.4 | Data Stream Protocol    | Not adopted     | Shiny chunk/tool messages do not implement the Data Stream wire format.                                                            |
|   3.5 | Assistant Transport     | Not adopted     | The Shiny bridge does not implement Assistant Transport state snapshots, commands, and converters.                                 |

### Named runtime integrations

| Order | Official page                    | Status             | Decision                                                                                              |
| ----: | -------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------- |
|   4.1 | AI SDK overview                  | Not adopted        | No `@assistant-ui/ai-sdk` runtime.                                                                    |
|   4.2 | AI SDK v7                        | Not adopted        | R/Shiny messages are not AI SDK UIMessage transport.                                                  |
|   4.3 | AI SDK v6 legacy                 | Not adopted        | Legacy integration is not bundled.                                                                    |
|   4.4 | AI SDK v5 legacy                 | Not adopted        | Legacy integration is not bundled.                                                                    |
|   4.5 | AI SDK v4 legacy                 | Not adopted        | Its data-stream route is also not bundled.                                                            |
|   5.1 | Eve overview                     | Not adopted        | No Eve channel/session converter.                                                                     |
|   5.2 | Eve quickstart                   | Not adopted        | Eve CLI/Next.js setup is outside the R package.                                                       |
|   6.1 | LangGraph overview               | Not adopted        | No LangGraph SDK runtime or graph-state converter.                                                    |
|   6.2 | LangGraph quickstart             | Not adopted        | No `useLangGraphRuntime` path.                                                                        |
|   6.3 | LangGraph streaming              | Not adopted        | Shiny events are not LangGraph event streams.                                                         |
|   6.4 | LangGraph Generative UI          | Not adopted        | Local `on_data_ui()`/`on_generative_ui()` are not a LangGraph adapter.                                |
|   6.5 | LangGraph interrupts and editing | Not adopted        | Local approvals/edits have no checkpoint semantics.                                                   |
|   6.6 | LangGraph threads                | Not adopted        | Package thread IDs are not LangGraph thread lifecycle.                                                |
|   6.7 | LangGraph agent state            | Not adopted        | Similar local state snapshots are not AG/LangGraph protocol compatibility.                            |
| 6.8.1 | LangGraph tutorial introduction  | Not applicable now | Depends on the unadopted runtime.                                                                     |
| 6.8.2 | Tutorial: setup frontend         | Not applicable now | Next.js template setup is not an R installation path.                                                 |
| 6.8.3 | Tutorial: generative UI          | Not applicable now | Local data UI does not establish LangGraph tool binding.                                              |
| 6.8.4 | Tutorial: approval UI            | Not applicable now | Local approval cards are not LangGraph interrupt/resume.                                              |
|     7 | LangChain React Runtime          | Not adopted        | No `@assistant-ui/react-langchain`; ellmer is not JavaScript LangChain.                               |
|   8.1 | Google ADK overview              | Not adopted        | No ADK event/session schema.                                                                          |
|   8.2 | Google ADK quickstart            | Not adopted        | No ADK route/stream/runtime helpers.                                                                  |
|   8.3 | Google ADK API reference         | Not adopted        | Local session loaders are not ADK adapters.                                                           |
|   8.4 | Google ADK hooks                 | Not adopted        | Similar callbacks do not implement typed ADK events.                                                  |
|   9.1 | A2A overview                     | Not adopted        | No A2A v1.0 client/task/artifact state machine.                                                       |
|   9.2 | A2A quickstart                   | Not adopted        | A generic R HTTP handler is not `useA2ARuntime`.                                                      |
|   9.3 | A2A client and hooks             | Not adopted        | No A2A JSON/SSE/ProtoJSON client.                                                                     |
|  10.1 | AG-UI overview                   | Not adopted        | No AG-UI client or event converter.                                                                   |
|  10.2 | AG-UI quickstart                 | Not adopted        | Shiny transport is not AG-UI wire compatibility.                                                      |
|  10.3 | AG-UI runtime options            | Not adopted        | Threads, steering, and interrupt metadata are different contracts.                                    |
|  10.4 | AG-UI agent state                | Not adopted        | Local state messages are not `STATE_SNAPSHOT/STATE_DELTA` events.                                     |
|  11.1 | OpenCode overview                | Not adopted        | OpenCode has its own SDK/runtime; the R package named codeagent is unrelated.                         |
|  11.2 | OpenCode quickstart              | Not adopted        | No OpenCode server/client runtime.                                                                    |
|  11.3 | OpenCode hooks                   | Not adopted        | Local permissions/questions do not implement OpenCode hooks.                                          |
|    12 | Claude Managed Agents            | Not adopted        | `make_claude_handler()` drives ClaudeAgentSDK/CLI, not hosted Managed Agents sessions and event logs. |

## Integrations

| Order | Official page             | Status                        | R/Shiny decision                                                                                                                       |
| ----: | ------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
|     1 | Integrations overview     | Adapted concept               | Runtime and backend infrastructure remain separate, but no third-party adapter is implied.                                             |
|   2.1 | Vercel AI SDK             | Not adopted                   | No AI SDK runtime/package.                                                                                                             |
|   2.2 | Cloudflare Agents         | Not adopted                   | No Durable Object/WebSocket AI SDK integration.                                                                                        |
| 2.3.1 | Mastra overview           | Not adopted                   | No Mastra or AI SDK bridge.                                                                                                            |
| 2.3.2 | Mastra full-stack         | Not applicable                | Next.js co-located route architecture is not the Shiny server.                                                                         |
| 2.3.3 | Mastra separate server    | Not adopted                   | No Mastra AssistantTransport client.                                                                                                   |
|     3 | LLM Gateways              | Backend-owned, not an adapter | Applications may configure compatible R clients, but the package does not claim named gateway integrations.                            |
|   4.1 | Helicone                  | Not adopted                   | No built-in proxy/telemetry wiring.                                                                                                    |
|   4.2 | Langfuse                  | Not adopted                   | No AI SDK/OpenTelemetry integration.                                                                                                   |
|   4.3 | LangSmith                 | Not adopted                   | No AI SDK wrapper or LangGraph integration.                                                                                            |
|   5.1 | Clerk                     | Not applicable                | Host deployment authentication is not a Clerk/Next.js adapter.                                                                         |
|   5.2 | better-auth               | Not applicable                | Shiny sessions are not better-auth sessions.                                                                                           |
|   5.3 | Auth.js                   | Not applicable                | No Auth.js route/session integration.                                                                                                  |
|     6 | Custom thread persistence | Adapted                       | Client storage, server loaders, and R stores meet related needs but do not implement `RemoteThreadListAdapter`/`ThreadHistoryAdapter`. |
|     7 | Custom attachment uploads | Partial                       | Built-in attachment transfer works; presigned object-storage upload/cancel/remove is not provided.                                     |

## React Native and Ink

Both families are **Not applicable** to a browser-based native Shiny
output binding. Their index, migration, custom-backend, primitives,
hooks, and adapters pages describe separate `@assistant-ui/react-native`
or `@assistant-ui/react-ink` applications. Shared runtime ideas do not
make native views, terminal components, or their adapters part of this R
package.

## Cloud

| Order | Official page            | Status                     | Decision                                                                                            |
| ----: | ------------------------ | -------------------------- | --------------------------------------------------------------------------------------------------- |
|     1 | Cloud Persistence        | Future option, not adopted | Existing package persistence is not Assistant Cloud.                                                |
|     2 | AI SDK                   | Not adopted                | Requires an unadopted AI SDK/Cloud stack.                                                           |
|     3 | AI SDK + assistant-ui    | Not adopted                | Cloud-backed hooks do not replace the Shiny ExternalStore bridge.                                   |
|     4 | LangGraph + assistant-ui | Not adopted                | Requires the unadopted LangGraph runtime.                                                           |
|     5 | User Authorization       | Future security design     | A hosted Cloud token/workspace model would require a separate public integration and threat review. |

## Utilities

| Order | Official page | Status            | Decision                                                               |
| ----: | ------------- | ----------------- | ---------------------------------------------------------------------- |
|     1 | heat-graph    | Not applicable    | Standalone React activity visualization, not a current R wrapper.      |
|     2 | tw-shimmer    | Maintainer option | A CSS plugin is not an end-user package capability.                    |
|     3 | react-o11y    | Future option     | Trace visualization would require an explicit R/backend span contract. |

## Migrations

All migration pages are **Maintainer-only** unless noted. R users
receive a precompiled bundle and do not run React codemods.

| Order | Official page        | Decision                                                                 |
| ----: | -------------------- | ------------------------------------------------------------------------ |
|     1 | Migration Guides     | Upstream maintenance index.                                              |
|     2 | Deprecation Policy   | Governance input; it does not replace this package’s R lifecycle policy. |
|     3 | Tools to Toolkits    | Not applied to the public R callback contract.                           |
|     4 | Migration to v0.11   | Current source already uses MessagePart-era concepts.                    |
|     5 | Migration to v0.12   | Current internal runtime/state APIs have been updated where used.        |
|     6 | Migration to v0.14   | Relevant component changes are absorbed in the bundled tree.             |
|     7 | Migration to v0.15   | Current package pins the 0.15 line.                                      |
|     8 | react-langgraph v0.7 | Not applicable because LangGraph is not adopted.                         |
|     9 | Old React versions   | Contributors follow the lockfile; R users do not provide React.          |

## Copilots (experimental)

| Order | Official page              | Status                   | R/Shiny decision                                                                              |
| ----: | -------------------------- | ------------------------ | --------------------------------------------------------------------------------------------- |
|     1 | Intelligent Components     | Partial concept          | The addin has IDE context and tools, but no compatibility with the experimental Copilots API. |
|     2 | `makeAssistantVisible`     | Not adopted              | Arbitrary host Shiny DOM is not serialized into model-readable/editable components.           |
|     3 | `useAssistantInstructions` | Backend-owned equivalent | Handler/provider instructions may be configured in R; the React hook is not exported.         |
|     4 | Model Context              | Partial                  | Selected IDE context and capability metadata use a narrower Shiny-owned protocol.             |
|     5 | Assistant Frame API        | Not adopted              | Sandboxed artifact iframes are not an Assistant Frame model-context bridge.                   |

## API Reference boundary

The upstream API Reference documents React packages. The public R API
remains the package reference for `assistantUIOutput()`,
`assistantUIServer()`, handler factories, stores, themes, addins,
session loaders, tool-view configuration, and plotting helpers.

| API family order | Upstream child pages                                                                                        | Local classification                                                            |
| ---------------: | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
|                1 | Overview                                                                                                    | Architecture mapping only; not an R export catalog.                             |
|                2 | Tools: overview, toolkits, component tools, rendering, status, interactables, legacy interactables          | Rendering/status map to R callbacks; toolkits/interactables are not exposed.    |
|                3 | Model Context: overview, context, registry                                                                  | Partial concept mapping; React registries remain internal.                      |
|                4 | Transport: overview, Assistant Transport, Assistant Frame                                                   | Shiny transport is custom and is not protocol-compatible with either named API. |
|                5 | External Store: overview, message conversion, runtime                                                       | Closest internal mapping; React types/helpers are not public R objects.         |
|                6 | Voice: overview, sessions, speech/dictation                                                                 | Dictation is adapted; speech UI partial; realtime sessions absent.              |
|                7 | Generative UI: overview, JSONGenerativeUI, components, actions, spec, rendering, Slack, Teams, A2UI, tokens | Local primitive/data callbacks are narrower; A2UI remains a future plan.        |
|                8 | Primitives: all primitive pages                                                                             | Internal building blocks configured through whole-widget R options/callbacks.   |
|                9 | Hooks: overview, composer triggers, model context, primitives, runtimes, state                              | Internal React lifecycle/state APIs only.                                       |
|               10 | Adapters: overview, attachments, feedback, model, persistence, runtime, suggestions                         | Several needs have Shiny-native equivalents; interfaces are not R exports.      |
|               11 | Runtimes: assistant, attachment, composer, message part, message, queue, thread list/item/thread            | Internal state machine only.                                                    |
|               12 | Context Providers: overview, AssistantRuntimeProvider, scoped providers                                     | Mounted internally by the widget.                                               |
|               13 | Integrations: overview, AI SDK, data stream, Cloud AI SDK, Eve                                              | Not adopted.                                                                    |
|               14 | Utilities: overview, miscellaneous                                                                          | Internal or not exposed.                                                        |

## Indexed pages outside the current sidebar

The upstream index also exposes pages that are not currently in the
visible root navigation. Their status follows the same evidence: WebMCP
is not adopted; Vue is a separate, not-applicable surface; Streamdown,
Mermaid, custom scrollbar, message timing, and part grouping are already
classified above through their visible component pages. Examples and
design-system catalogs are inspiration, not automatic package
commitments.

## Current gaps and future plans

A2UI is the explicit future protocol plan: it is not a current AG-UI or
A2UI integration. True branching remains partial because edit/reload
currently replaces the linear message tail rather than preserving
switchable alternatives. AI SDK, LangGraph, LangChain, A2A, AG-UI,
OpenCode, and the other named runtimes remain unadopted until their
protocol and lifecycle contracts are implemented and verified, not
merely called through a generic R handler.

|    Priority | Item                               | Current boundary                                                                                                                         |
| ----------: | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Future plan | A2UI                               | Add only after a Shiny-facing contract, surface lifecycle/history, action security, optional dependency review, and browser tests exist. |
|         Gap | True branching                     | Preserve and switch alternative message/backend histories instead of truncating a linear array.                                          |
|         Gap | Resumable streams                  | Resume in-flight output across disconnects; completed history reload is not sufficient.                                                  |
|         Gap | Long-thread virtualization         | Avoid mounting an entire very long transcript.                                                                                           |
|         Gap | Realtime voice and speech controls | Dictation alone does not satisfy these pages.                                                                                            |
|         Gap | Message timing                     | Add explicit TTFT, duration, rate, and count metadata if product demand justifies it.                                                    |
|         Gap | Browser MCP/MCP Apps               | Backend MCP tools do not provide browser server management or MCP resource apps.                                                         |
|    Optional | Mermaid/Streamdown                 | Evaluate security, bundle size, and streaming behavior before adding either renderer.                                                    |
|    Optional | RTL                                | Expose direction, wire providers, remove remaining physical styles, and add browser verification before claiming support.                |

## Re-review boundary

This review covers the current visible sidebar order and relevant
indexed pages. A status changes only when source, public R contract,
tests, and installed-package browser behavior support the claim. New
upstream pages or dependency upgrades should be reviewed in their new
navigation position rather than treated as adopted by association.
