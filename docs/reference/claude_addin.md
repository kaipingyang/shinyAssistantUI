# Open a Claude Code chat inside RStudio

Launches the shinyAssistantUI chat (backed by ClaudeAgentSDK) in the
RStudio Viewer pane or a dialog, rooted at the current project so
Claude's agentic tools (Read/Edit/Bash/Grep) act on your project files.
The active editor file and any selection are sampled again for each new
prompt (rather than frozen at startup); the composer can hide selection
text while keeping the active-file reference, so you can ask "explain
this" / "refactor the selection".

## Usage

``` r
claude_addin(
  project = NULL,
  viewer = c("pane", "dialog", "browser"),
  permission_mode = c("default", "plan", "acceptEdits", "bypassPermissions"),
  prewarm = TRUE,
  models = NULL,
  options = NULL,
  background = TRUE
)
```

## Arguments

  - project:
    
    Project root (Claude's working directory). Defaults to the active
    RStudio project, else `getwd()`.

  - viewer:
    
    Where to show the gadget: `"pane"` (Viewer pane, default),
    `"dialog"`, or `"browser"`. Forced to `"browser"` when not running
    in RStudio.

  - permission\_mode:
    
    Claude tool-use permission policy:
    
      - `"default"`  
        File edits and shell commands require per-action approval via
        the in-chat approval card (safest — recommended for
        shared/production projects).
    
      - `"plan"`  
        Read-only analysis and planning; edits are not permitted.
    
      - `"acceptEdits"`  
        File edits are auto-approved; shell commands still prompt.
    
      - `"bypassPermissions"`  
        All tool calls run without prompts (fastest, use with care).
    
    Ignored when `options` is supplied directly.

  - prewarm:
    
    Logical (default `TRUE`). Pre-connect the Claude CLI after the
    interface mounts so the first message does not pay the cold-start
    cost (see `assistantUIServer()`). A visible warming indicator
    remains until initialization completes. Set `FALSE` to defer
    connecting until the first message.

  - models:
    
    Optional character vector of model names/aliases to offer in the
    Settings "Model" selector (e.g. `c("sonnet", "opus")`). A "Default"
    option is always prepended. Omit to use the built-in tiers
    (Default/Haiku/Sonnet/Opus). Switching is a live `set_model` (no
    reconnect).

  - options:
    
    Optional
    [ClaudeAgentSDK::ClaudeAgentOptions](https://kaipingyang.github.io/ClaudeAgentSDK/reference/ClaudeAgentOptions.html)
    to fully override all defaults.

  - background:
    
    Logical (default `TRUE`). Run the chat as an RStudio/Positron
    **background job** (via `rstudioapi::jobRunScript()`) shown in the
    Viewer, so the R console stays free while you chat. IDE integration
    (editor context, open-file, Files pane, markers, save-before-edit)
    still works from the job via child-process `rstudioapi`. Falls back
    to the classic blocking gadget when background jobs aren't available
    (e.g. plain R / browser). Set `FALSE` to force the classic gadget.

## Value

Invisibly, the result of `shiny::runGadget()`.

## Details

Thread history is stored in `~/.claude_addin_session_map.rds` (user
home, not the project), so conversations persist across project switches
and RStudio restarts.

Registered as the RStudio addin **"Claude Code Chat"**; also callable
programmatically.

## Examples

``` r
if (FALSE) { # \dontrun{
  # From the RStudio Addins menu: "Claude Code Chat", or:
  claude_addin()
  claude_addin(permission_mode = "acceptEdits")   # auto-approve file edits
  claude_addin(viewer = "dialog")                 # floating dialog instead of pane
} # }
```
