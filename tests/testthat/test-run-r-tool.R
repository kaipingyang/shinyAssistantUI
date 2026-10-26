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

# ── Plan 163: MCP result carries partial output together with the error ──────
load_run_r_script <- function(remote) {
  script <- system.file("mcp", "run_r_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/run_r_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(sdk_has_stdio_mcp())
  withr::local_envvar(SHINY_ASSISTANT_UI_RUN_R_NO_SERVE = "1")
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  env$.run_remote <- remote
  env
}

test_that("run_r MCP error result includes output printed before the error", {
  env <- load_run_r_script(function(url, code, timeout = 60000) {
    list(ok = FALSE, output = "[1] 1", error = "line 2 (`prin(2)`): could not find function \"prin\"")
  })
  res <- env$.run_r_result("print(1)\nprin(2)")
  expect_true(isTRUE(res$isError))
  text <- res$content[[1]]$text
  expect_match(text, "[1] 1", fixed = TRUE)
  expect_match(text, "Error: line 2", fixed = TRUE)
  expect_lt(regexpr("[1] 1", text, fixed = TRUE), regexpr("Error:", text, fixed = TRUE))
})

test_that("run_r MCP success result returns full output or a no-output marker", {
  env <- load_run_r_script(function(url, code, timeout = 60000) {
    list(ok = TRUE, output = if (grepl("a", code)) "[1] 1\n[1] 2" else "", error = NULL)
  })
  res <- env$.run_r_result("a\nb")
  expect_null(res$isError)
  expect_identical(res$content[[1]]$text, "[1] 1\n[1] 2")
  expect_identical(env$.run_r_result("x <- 1")$content[[1]]$text, "(no visible output)")
})

# ── Plan 163 batch 2: output review before returning to Claude ──────────────
load_review_script <- function(review, cap = list(ok = TRUE, output = "secret", error = NULL)) {
  withr::local_envvar(
    CLAUDE_ADDIN_REVIEW_URL = "ipc:///tmp/review-test.sock",
    CLAUDE_ADDIN_THREAD_ID = "thread-9",
    .local_envir = parent.frame()
  )
  env <- load_run_r_script(function(url, code, timeout = 60000) cap)
  env$.review_remote <- review
  env
}

test_that("approved output is returned unchanged and the request carries the thread", {
  seen <- NULL
  env <- load_review_script(function(url, payload, timeout) {
    seen <<- payload
    list(decision = "approve", text = payload$text, request_id = payload$request_id)
  })
  res <- env$.run_r_result("secret_value")
  expect_identical(res$content[[1]]$text, "secret")
  expect_null(res$isError)
  expect_identical(seen$type, "run_r_output_review")
  expect_identical(seen$thread_id, "thread-9")
  expect_identical(seen$code, "secret_value")
  expect_identical(seen$text, "secret")
  expect_false(seen$is_error)
})

test_that("edited output replaces the original and is marked as edited", {
  env <- load_review_script(function(url, payload, timeout) {
    list(decision = "edit", text = "redacted", request_id = payload$request_id)
  })
  text <- env$.run_r_result("x")$content[[1]]$text
  expect_match(text, "redacted", fixed = TRUE)
  expect_match(text, "edited", ignore.case = TRUE)
  expect_false(grepl("secret", text, fixed = TRUE))
})

test_that("rejection, timeout and malformed replies never leak the output", {
  replies <- list(
    list(decision = "reject", reason = "user"),
    list(decision = "reject", reason = "timeout"),
    NULL,
    list(decision = "edit", text = 5),
    list(decision = "approve", text = "different")
  )
  for (reply in replies) {
    env <- load_review_script(function(url, payload, timeout) {
      if (is.list(reply)) reply$request_id <- payload$request_id
      reply
    })
    res <- env$.run_r_result("x")
    text <- res$content[[1]]$text
    if (identical(reply$decision, "approve")) {
      # approve always sends the reviewed original, never reply-supplied text
      expect_identical(text, "secret")
    } else {
      expect_true(isTRUE(res$isError))
      expect_false(grepl("secret", text, fixed = TRUE))
      expect_match(text, "did not approve", fixed = TRUE)
      expect_match(text, "already ran", fixed = TRUE)
    }
  }
})

test_that("review covers error output too", {
  env <- load_review_script(
    function(url, payload, timeout) list(decision = "reject", reason = "user",
                                         request_id = payload$request_id),
    cap = list(ok = FALSE, output = "secret", error = "boom")
  )
  res <- env$.run_r_result("x")
  expect_true(isTRUE(res$isError))
  expect_false(grepl("secret|boom", res$content[[1]]$text))
})

test_that("an approval for a different request never releases this output", {
  env <- load_review_script(function(url, payload, timeout) {
    list(decision = "approve", text = payload$text, request_id = "someone-else")
  })
  res <- env$.run_r_result("x")
  expect_true(isTRUE(res$isError))
  expect_false(grepl("secret", res$content[[1]]$text, fixed = TRUE))
})
