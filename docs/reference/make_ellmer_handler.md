# Create an ellmer streaming handler for assistantUIServer

Wraps an `ellmer` chat object into an `assistantUIServer`-compatible
handler. Supports per-thread conversation history, tool calling with
optional human-in-the-loop approval, attachments, and optional SQLite
session persistence.

## Usage

``` r
make_ellmer_handler(
  chat,
  tools = NULL,
  approval_tools = character(0),
  store = NULL
)
```

## Arguments

  - chat:
    
    A zero-argument function returning a new `ellmer` chat object.
    Called once per thread on first message. Example: `function()
    chat_openai_compatible(...)`.

  - tools:
    
    A list of `ellmer::tool()` objects to register on each chat. If
    `NULL`, no tools are registered.

  - approval\_tools:
    
    Character vector of tool names that require human approval before
    execution. Defaults to `character(0)` (no approval).

  - store:
    
    Optional session store created by `ellmer_session_store()`. When
    provided, chat state is persisted to SQLite across R restarts.

## Value

A `coro::async` handler function compatible with `assistantUIServer()`.

## Examples

``` r
if (FALSE) { # \dontrun{
store <- ellmer_session_store(".sessions/chat.db")

handler <- make_ellmer_handler(
  chat           = function() chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  ),
  tools          = list(get_weather, calculate),
  approval_tools = c("calculate"),
  store          = store
)

assistantUIServer("chat", handler = handler, show_thread_list = TRUE,
  on_session_load = make_ellmer_session_loader(store))
} # }
```
