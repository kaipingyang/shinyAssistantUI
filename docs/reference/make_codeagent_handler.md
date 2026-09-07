# Use codeagent as the backend engine

Adapter that lets `assistantUIServer()` drive a
[codeagent](https://github.com/kaipingyang/codeagent) agent instead of a
bare `ellmer::Chat` — gaining codeagent's harness (agent loop, central
permission gate, compaction, skills/hooks, sessions, and rich tool
output).

## Usage

``` r
make_codeagent_handler(
  client_factory,
  approval_tools = character(0),
  permission_mode = "default",
  store = NULL,
  stream_fn = NULL,
  gate_fn = NULL
)
```

## Arguments

  - client\_factory:
    
    `function()` returning a codeagent client. Called once per thread
    and cached for the lifetime of this handler.

  - approval\_tools:
    
    Optional tool names to additionally force through the approval card,
    on top of `permission_mode`.

  - permission\_mode:
    
    A current codeagent permission mode: `"default"`, `"plan"`,
    `"accept_edits"`, `"bypass"`, `"dont_ask"`, `"auto"`, or `"bubble"`.
    `"bypass"` auto-runs tools and is for trusted environments.

  - store:
    
    Optional persistence adapter with `save(thread_id, chat, ...)`. It
    receives the underlying ellmer chat after successful non-Shield
    turns. Shield-backed turns are not persisted by this adapter.

  - stream\_fn:
    
    Advanced/testing streaming function. Defaults to
    `codeagent::codeagent_stream_async`.

  - gate\_fn:
    
    Advanced/testing permission-gate installer. Defaults to
    `codeagent::install_permission_gate`.

## Value

A `coro::async` handler suitable for `assistantUIServer()`. It has
`warmup` and `teardown` attributes for session lifecycle management.

## Details

When a client has an active `DataShield`, assistant text is held
server-side, scanned as one complete response, and only then released to
the browser. Thinking, raw tool arguments, and rich display payloads are
suppressed in this mode so they cannot bypass the shield through another
UI callback.

## See also

`make_ellmer_handler()` for the lighter bare-ellmer backend.
