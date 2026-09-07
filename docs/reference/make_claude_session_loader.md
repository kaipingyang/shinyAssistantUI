# Create an on\_session\_load callback for ClaudeAgentSDK sessions

Returns a function suitable for the `on_session_load` argument of
`assistantUIServer()`, loading historical messages from Claude session
files.

## Usage

``` r
make_claude_session_loader(session_map_path = ".claude_session_map.rds")
```

## Arguments

  - session\_map\_path:
    
    Path to the session map `.rds` file (same path passed to
    `make_claude_handler()`).

## Value

A function with signature `function(session_id, thread_id, send_thread,
cursor = NULL, limit = 50L, project = NULL)`. `project` is the owning
Workspace directory; when omitted, the legacy global Claude session
lookup remains in effect.
