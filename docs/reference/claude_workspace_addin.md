# Open a multi-project Claude Workspace inside RStudio

Launches the same Claude Code chat core as `claude_addin()` in workspace
mode. Sessions are grouped and routed by project, and up to four
different threads may run concurrently. Existing saved projects are
included automatically.

## Usage

``` r
claude_workspace_addin(
  project = NULL,
  projects = NULL,
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

  - projects:
    
    Optional character vector of additional project directories. Paths
    are canonicalized and deduplicated; missing paths remain registered
    but are not queried until they become available.

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

Invisibly, the result of `shiny::runGadget()` or the background-job
launcher metadata.

## Examples

``` r
if (FALSE) { # \dontrun{
  claude_workspace_addin()
  claude_workspace_addin(projects = c("~/project-a", "~/project-b"))
} # }
```
