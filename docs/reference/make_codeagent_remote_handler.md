# Use codeagent as an out-of-process backend engine

Like `make_codeagent_handler()`, but runs the `codeagent` agent in a
separate R **worker process** pinned to an isolated library with
compatible `codeagent`, `ellmer`, and `curl` versions. The MAIN Shiny
process **never loads codeagent / ellmer / curl** — so it is safe inside
a session whose default library has an old, incompatible `curl` (the R
"one namespace version per session" trap). Streaming, tool display, and
permission approval are marshaled over a socket; the in-app approval
card + `wait_for_approval` bridge is reused unchanged, just across the
process boundary.

## Usage

``` r
make_codeagent_remote_handler(
  config = list(),
  libpath = NULL,
  renviron = NULL,
  permission_mode = "default",
  approval_tools = character(0)
)
```

## Arguments

  - config:
    
    Named list of client construction parameters evaluated *inside* the
    worker: `base_url`, `model`, `api_key`, `cwd`. Missing values fall
    back to `OPENAI_BASE_URL` / `OPENAI_MODEL` / `OPENAI_API_KEY` (read
    from `renviron`). A live `Chat` object cannot be passed (not
    serializable).

  - libpath:
    
    Isolated R library root the worker prepends to `.libPaths()`. It
    must contain compatible `codeagent`, `ellmer`, and `curl` versions;
    provisioning and location are deployment-specific.

  - renviron:
    
    Optional path to a `.Renviron` the worker reads for credentials (a
    fresh R process does not auto-read a project `.Renviron`).

  - permission\_mode:
    
    Gate mode installed in the worker (default `"default"` →
    write/execute tools prompt via the approval card).

  - approval\_tools:
    
    Optional tool names to additionally force through approval (mapped
    to the gate's rules). Approve/deny only.

## Value

A `coro::async` handler for `assistantUIServer()`.

## Details

Use this when the host session cannot load the new `curl`/`ellmer`
in-process (for example, a long-lived host session with a legacy system
stack). On a machine whose whole environment already has a new `curl`,
the lighter in-process `make_codeagent_handler()` works too.

**IMPORTANT:** The MAIN process must never
`requireNamespace("codeagent")` — that would load ellmer/curl into MAIN.
Availability is checked with `find.package()`; the worker is spawned
only when a turn actually runs (or via `warmup`).

**Phase B scope:** `register_tools = TRUE` built-in toolset +
approve/deny permission gating. Host-supplied domain tools
(register\_tools = FALSE) are not yet supported across the process
boundary (a live `ellmer::Chat` cannot be serialized) — use
`make_codeagent_handler()` in-process for that.

## See also

`make_codeagent_handler()` (in-process).
