# List Claude sessions for sidebar injection

Helper to fetch sessions from `ClaudeAgentSDK::list_sessions()` and
format them for `ctrl$send_sessions()`.

## Usage

``` r
list_claude_sessions(
  directory = here::here(),
  limit = 100L,
  archived_ids = character()
)
```

## Arguments

  - directory:
    
    Project directory to filter sessions. Defaults to `here::here()`.

  - limit:
    
    Maximum number of sessions to return.

  - archived\_ids:
    
    Character vector of session ids to mark as archived in the returned
    list (so the sidebar can show them under an archived section).

## Value

A list suitable for `ctrl$send_sessions(list(sessions = ...))`.
