# Create a ClaudeAgentSDK handler for assistantUIServer

Wraps `ClaudeAgentSDK` into an `assistantUIServer`-compatible handler.
Supports streaming, tool approval UI, thinking output, attachments, and
session persistence across R restarts.

## Usage

``` r
make_claude_handler(
  options = NULL,
  cwd_provider = NULL,
  thinking_provider = NULL,
  models = NULL,
  session_map_path = ".claude_session_map.rds",
  memory_guard_config = NULL,
  on_memory_observation = NULL,
  memory_sampler = NULL
)
```

## Arguments

  - options:
    
    A `ClaudeAgentOptions` object. Defaults to
    `ClaudeAgentOptions(permission_mode = "default",
    permission_prompt_tool_name = "stdio", include_partial_messages =
    TRUE)`.

  - cwd\_provider:
    
    Optional function returning the working directory used when a
    thread's CLI client connects. It may declare `thread_id` and
    `project`; arguments are filtered by formals, so existing
    zero-argument providers remain compatible.

  - thinking\_provider:
    
    Optional zero-argument function returning the current thinking level
    to apply on connect.

  - models:
    
    Optional character vector of model ids to offer in the model
    selector (a "Default" option is always prepended).

  - session\_map\_path:
    
    Path to the `.rds` file used to persist `thread_id -> session_id`
    mappings. Defaults to `".claude_session_map.rds"` in the current
    working directory.

  - memory\_guard\_config:
    
    Optional internal memory-pressure guard configuration. `NULL` keeps
    the guard disabled for generic handlers.

  - on\_memory\_observation:
    
    Optional callback receiving the guard's exact sampled observation
    and state transition.

  - memory\_sampler:
    
    Optional internal sampler injection used by deterministic
    verification; production callers should leave it `NULL`.

## Value

A `coro::async` handler function compatible with `assistantUIServer()`.
The returned handler declares `supports_concurrent_threads = TRUE`: each
thread owns a separate Claude client while normal turns and compaction
remain strict single-consumer operations within that thread. This lets
`assistantUIServer(max_concurrent_runs = ...)` run different threads
under its bounded global scheduler.

## Examples

``` r
if (FALSE) { # \dontrun{
handler <- make_claude_handler()

server <- function(input, output, session) {
  ctrl <- assistantUIServer("chat", handler = handler,
                            show_thread_list = TRUE)
  # inject sessions into sidebar
  shiny::observe({
    sessions <- list_claude_sessions()
    ctrl$send_sessions(list(sessions = sessions))
  })
}
} # }
```
