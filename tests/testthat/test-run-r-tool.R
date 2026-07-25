# Angle B (Plan 22): Claude-agentic run_r in-process MCP tool.
# Pure-helper unit tests — no CLI, no live env-server; run_remote is mocked.

test_that(".addin_run_r_allowed_tools adds run_r only when autorun is on", {
  expect_equal(.addin_run_r_allowed_tools(TRUE,  c("Read")), c("Read", "mcp__r_session__run_r"))
  expect_equal(.addin_run_r_allowed_tools(FALSE, c("Read")), c("Read"))
  expect_equal(.addin_run_r_allowed_tools(TRUE,  NULL), "mcp__r_session__run_r")
  expect_null(.addin_run_r_allowed_tools(FALSE, NULL))
  # idempotent: don't duplicate if already present
  expect_equal(.addin_run_r_allowed_tools(TRUE, "mcp__r_session__run_r"), "mcp__r_session__run_r")
})

sdk_has_stdio_mcp <- function() {
  requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
    "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK")
}

test_that(".addin_run_r_server returns an EXTERNAL stdio config (not in-process sdk)", {
  skip_if_not(sdk_has_stdio_mcp())
  cfg <- .addin_run_r_server("ipc:///tmp/x.sock")
  # stdio — NOT 'sdk' — because the CLI stalls ~50s on the first message when an
  # in-process server is registered and the connection idles first (Plan 22).
  expect_equal(cfg$type, "stdio")
  expect_true(grepl("Rscript", cfg$command))
  script <- cfg$args[[length(cfg$args)]]
  expect_true(grepl("run_r_server\\.R$", script))
  expect_true(file.exists(script))
  # console_url + libpaths passed via the server's env
  expect_equal(cfg$env$CLAUDE_ADDIN_CONSOLE_URL, "ipc:///tmp/x.sock")
  expect_true(nzchar(cfg$env$R_LIBS))
})

test_that("run_r stdio server script parses and is curl-free", {
  script <- system.file("mcp", "run_r_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/run_r_server.R"
  skip_if_not(file.exists(script))
  expect_silent(parse(script))                       # valid R
  src <- paste(readLines(script), collapse = "\n")
  expect_true(grepl("mcp_serve_stdio", src))
  expect_true(grepl("run_r", src))
  expect_false(grepl("library\\(ellmer|ellmer::", src))   # no ellmer usage -> no curl
})

# ── console echo styling (classic R prompt + highlight/blue) ──────────────────
strip <- function(x) if (requireNamespace("cli", quietly = TRUE)) cli::ansi_strip(x) else x

# ── console echo styling (classic R prompt + highlight/blue) ──────────────────
test_that("console echo prefixes code with classic > / + prompts", {
  expect_equal(strip(.addin_console_prompt_code("summary(df)")), "> summary(df)")
  expect_equal(strip(.addin_console_prompt_code("a <- 1\nb <- 2")),
               c("> a <- 1", "+ b <- 2"))
})

test_that("console echo lines carry header, prompted code, and output/error", {
  ok <- strip(.addin_console_echo_lines("summary(df)", list(ok = TRUE, output = "OUT", error = NULL)))
  expect_true(any(grepl("Claude ran in console", ok)))
  expect_true(any(grepl("^> summary\\(df\\)$", ok)))
  expect_true("OUT" %in% ok)

  er <- strip(.addin_console_echo_lines("stop('x')", list(ok = FALSE, output = "", error = "boom")))
  expect_true(any(grepl("Error: boom", er)))
})


# ── env-server robustness ─────────────────────────────────────────────────────
test_that(".addin_console_service_once on a closed socket returns NULL (no throw)", {
  skip_if_not(requireNamespace("nanonext", quietly = TRUE))
  u <- paste0("ipc://", tempfile("test-closed-", fileext = ".sock"))
  sock <- nanonext::socket("rep", listen = u)
  close(sock)
  # closed socket -> nanonext::context() would error; must be swallowed to NULL
  expect_null(.addin_console_service_once(sock, timeout = 50))
})
