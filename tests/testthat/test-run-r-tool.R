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

sdk_has_mcp <- function() {
  requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
    "create_sdk_mcp_server" %in% getNamespaceExports("ClaudeAgentSDK")
}

test_that(".addin_run_r_server builds a type='sdk' server 'r_session' with run_r", {
  skip_if_not(sdk_has_mcp())
  srv <- .addin_run_r_server("ipc:///tmp/x.sock",
                             run_remote = function(...) list(ok = TRUE, output = "", error = NULL))
  expect_equal(srv$type, "sdk")
  expect_equal(srv$name, "r_session")
  expect_true("run_r" %in% names(srv$instance$tools))
})

test_that("run_r handler formats a successful capture as MCP text content (never image)", {
  skip_if_not(sdk_has_mcp())
  srv <- .addin_run_r_server("u",
    run_remote = function(url, code, timeout = NULL) list(ok = TRUE, output = "RESULT_42", error = NULL))
  res <- srv$instance$tools$run_r$handler(list(code = "17 + 25"))
  expect_false(isTRUE(res$isError))
  expect_equal(res$content[[1]]$type, "text")
  expect_equal(res$content[[1]]$text, "RESULT_42")
  types <- vapply(res$content, function(x) x$type, character(1))
  expect_false("image" %in% types)   # D3: never send images/base64
})

test_that("run_r handler surfaces errors with isError = TRUE", {
  skip_if_not(sdk_has_mcp())
  srv <- .addin_run_r_server("u",
    run_remote = function(url, code, timeout = NULL) list(ok = FALSE, output = "", error = "boom"))
  res <- srv$instance$tools$run_r$handler(list(code = "stop('x')"))
  expect_true(isTRUE(res$isError))
  expect_true(grepl("boom", res$content[[1]]$text))
})

test_that("run_r handler yields a non-empty placeholder when output is empty", {
  skip_if_not(sdk_has_mcp())
  srv <- .addin_run_r_server("u",
    run_remote = function(url, code, timeout = NULL) list(ok = TRUE, output = "", error = NULL))
  res <- srv$instance$tools$run_r$handler(list(code = "invisible(1)"))
  expect_false(isTRUE(res$isError))
  expect_true(nzchar(res$content[[1]]$text))
})

test_that("run_r handler passes the code through to run_remote", {
  skip_if_not(sdk_has_mcp())
  seen <- new.env(parent = emptyenv())
  srv <- .addin_run_r_server("the-url",
    run_remote = function(url, code, timeout = NULL) {
      seen$url <- url; seen$code <- code
      list(ok = TRUE, output = "ok", error = NULL)
    })
  srv$instance$tools$run_r$handler(list(code = "summary(mtcars)"))
  expect_equal(seen$url, "the-url")
  expect_equal(seen$code, "summary(mtcars)")
})

# ── console echo styling (classic R prompt + highlight/blue) ──────────────────
strip <- function(x) if (requireNamespace("cli", quietly = TRUE)) cli::ansi_strip(x) else x

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
