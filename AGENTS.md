# AGENTS.md

Agent-facing operating guide for **shinyAssistantUI** (R Shiny htmlwidget wrapping
`@assistant-ui/react`). The canonical, detailed project doc is **[CLAUDE.md](./CLAUDE.md)** —
read it for architecture, the R↔JS bridge protocol, test coverage, and design history.
This file front-loads the operational rules that are easy to get wrong.

## 🔴 Rule #1 — After editing R **or** JS, rebuild + reinstall before testing

Example apps and verification scripts launch via `library(shinyAssistantUI)`, which loads
the **installed** package (byte-compiled `.rdb` in `~/R/.../library/`), **not** the dev
source tree. `callr::r_bg` background apps are separate processes — `devtools::load_all(".")`
does **not** reach them.

```bash
npm run build                                       # JS → dev inst/www/
R CMD INSTALL --no-multiarch --with-keep.source .   # R + inst/www/ → installed library
```

- Edited **R** (`R/*.R`) → reinstall (build not needed unless JS also changed).
- Edited **JS** (`srcjs/*`) → **build first**, then reinstall (htmlwidget serves JS from
  the *installed* `www/` via `system.file`; a dev-only build won't be seen by the browser).
- Order matters: **build → install** (install copies `inst/www/` into the package).

If you skip this, your verification runs against **stale code** and "new features don't work"
— a real trap that has cost multiple debugging rounds.

## 🔴 Rule #2 — Never `pkill -f <pattern>` from your own shell

`pkill -9 -f chrome` (or any `-f <str>`) matches the pkill command's **own** argv, which
contains that string → it **SIGKILLs its own shell** before finishing. This masquerades as
an OOM kill. Use exact-name match or kill via R instead:

```bash
pkill -9 -x chrome            # -x = exact process name, won't match the shell
pkill -9 -f headless_shell    # ONLY safe if "headless_shell" is NOT in your command line
```
```r
try(b$parent$get_browser()$get_process()$kill(), silent = TRUE)   # from chromote
```

## Verify in a real browser

Use `chromote` (real headless Chromium) — see the `shiny-browser-verify` skill and
`tests/verify/`. Reads DOM `data-*` attributes as ground truth. Drive the real composer
(contenteditable) via CDP `Input.insertText` + Enter key; don't shortcut with
`Shiny.setInputValue` (lazy per-thread callback registration would be skipped).

- Backends: ellmer AND ClaudeAgentSDK (via copilot-api at `:4141`). Load creds with
  `readRenviron(".Renviron")` **inside** the `callr` function (a fresh R process won't
  auto-read the project `.Renviron`).
- Batch example checks: `tests/verify/verify_examples_range.R <start> <end>` — split across
  **sub-agents** (separate process trees, ≤1 Chrome each) to stay under the shared cgroup
  memory limit (`cat /sys/fs/cgroup/memory.max`); strict per-app Chrome cleanup.
- SDK-alignment checks: `tests/verify/verify_sdk_alignment.R`, `verify_task_progress.R`.

## Test & regress

```bash
npx vitest run --no-file-parallelism --pool=forks   # JS (103 cases); single-fork caps memory
```
```r
devtools::load_all("."); testthat::test_dir("tests/testthat")   # R helpers
```

## Git

- Branch `feat/registry-migration`; `main` = v0.1.0 stable backup — do **not** merge without
  explicit confirmation.
- Push via SSH; GitHub token in `~/.Renviron` (`GITHUB_TOKEN`), no `gh` CLI.
- `.ellmer_sessions/` stays gitignored (chat data).
- Chinese comments in R are fine for CRAN; only **non-ASCII in string literals** triggers a
  WARNING (escape with `\uXXXX`).

## ClaudeAgentSDK notes

- R SDK talks to the `claude` CLI subprocess (stream-json), not the Python package.
- `/compact` has **no** SDK method (verified across R / local-python / official-github); it's
  a CLI slash command sent through the input stream (`client$send("/compact")`).
- Control ops as slash **actions** (client-side, not sent to AI): `/model`, `/permissions`,
  `/context`, `/compact`, `/mcp`, `/resume`, `/clear`, fork/tag/stoptask — dispatched by
  `make_claude_handler`'s `action_handler`, auto-wired by `assistantUIServer`.
- Aligned SDK→UI signals: cost/usage footer, subagent/Task progress cards (+ Stop → `stop_task`),
  rate-limit banner, status line, command auto-discovery (`get_server_info`), server-tool badge,
  approval card title/displayName/description, `task_updated` terminal state, hook-event status.
- SDK now at **v0.2.1** (installed): parses `server_tool_use`/`advisor_tool_result`/`task_updated`/
  `HookEventMessage`; `PermissionRequestMessage` has title/display_name/description;
  `ResultMessage` has api_error_status/deferred_tool_use; options add
  include_hook_events/strict_mcp_config/skills.
- **Real-machine data-shape finding (copilot-api :4141 + claude CLI, 2026-07-06)**: a web-search
  prompt yields content blocks `thinking/tool_use/text` only — **`server_tool_use` does NOT
  appear**; WebSearch arrives as a **client `tool_use` (name `WebSearch`)** and renders as a
  normal tool card. So the 🌐 server-tool badge path is **correct but dormant** on this backend
  (fixture-verified, ready if a backend emits `server_tool_use`/`advisor_tool_result`).
  `HookEventMessage` **is emitted by default** here (no `include_hook_events` needed) and does
  not disrupt rendering. Re-confirm server-tool shape if you switch to a backend that runs
  Anthropic server-side tools (advisor/web_search server variants).
