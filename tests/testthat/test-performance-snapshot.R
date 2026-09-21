test_that("Claude handler exposes a read-only performance snapshot", {
  skip_if_not_installed("ClaudeAgentSDK")
  requests <- list()
  client_factory <- function() {
    client <- new.env(parent = emptyenv())
    client$connect <- function() invisible(NULL)
    client$disconnect <- function() invisible(NULL)
    client$poll_messages <- function() list()
    client$set_model_async <- function(model, timeout_ms = 5000L,
                                       on_fulfilled = NULL, on_rejected = NULL) {
      requests[[length(requests) + 1L]] <<- list(resolve = on_fulfilled)
      invisible(paste0("request-", length(requests)))
    }
    client
  }
  testthat::local_mocked_bindings(
    .new_claude_client = function(options) client_factory()
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  on.exit(attr(handler, "cleanup")(), add = TRUE)

  snapshot <- attr(handler, "performance_snapshot")
  expect_true(is.function(snapshot))
  initial <- snapshot()
  expect_identical(initial$connected_clients, 0L)
  expect_identical(initial$coordinators, 0L)
  expect_identical(initial$active_turns, 0L)
  expect_identical(initial$pending_model_switches, 0L)
  expect_identical(initial$usage_probes_pending, 0L)

  attr(handler, "warmup")("perf-a")
  attr(handler, "warmup")("perf-b")
  warmed <- snapshot()
  expect_identical(warmed$connected_clients, 2L)
  expect_identical(warmed$coordinators, 2L)
  expect_setequal(names(warmed$threads), c("perf-a", "perf-b"))
  expect_true(all(vapply(warmed$threads, function(thread) {
    identical(thread$coordinator$idle_poll_ms, 100)
  }, logical(1))))

  attr(handler, "action_handler")(
    "model:sonnet", "perf-a", function(...) invisible(NULL)
  )
  expect_identical(snapshot()$pending_model_switches, 1L)
  requests[[1L]]$resolve(list())
  expect_identical(snapshot()$pending_model_switches, 0L)
})


test_that("Claude handler memory guard is observable and blocks model-producing admissions", {
  skip_if_not_installed("ClaudeAgentSDK")
  gc_calls <- 0L
  client_creations <- 0L
  high <- list(
    available = TRUE, source = "smaps_rollup",
    pss_bytes = 300, rss_bytes = 310, captured_at = Sys.time()
  )
  config <- list(
    enabled = TRUE,
    soft_pss_bytes = 100, hard_pss_bytes = 200,
    soft_rss_bytes = 125, hard_rss_bytes = 225,
    consecutive_samples = 2L, hysteresis = 0.8,
    active_interval = 100, idle_interval = 100, settle_delay = 100
  )
  testthat::local_mocked_bindings(
    .read_linux_memory_snapshot = function(...) high,
    .claude_full_gc = function() { gc_calls <<- gc_calls + 1L; invisible(NULL) },
    .new_claude_client = function(options) {
      client_creations <<- client_creations + 1L
      stop("client must not be created under hard pressure")
    }
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "bypassPermissions",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds"),
    memory_guard_config = config
  )
  on.exit(attr(handler, "cleanup")(), add = TRUE)

  observe_guard <- attr(handler, ".memory_guard_observe")
  expect_true(is.function(observe_guard))
  observe_guard(); observe_guard()
  snapshot <- attr(handler, "performance_snapshot")()
  expect_identical(snapshot$memory_guard$state, "hard_pending")
  expect_true(snapshot$memory_guard$settling)
  expect_identical(gc_calls, 1L)

  error_message <- NULL
  done <- FALSE
  handler_promise <- handler(
    message = "must be rejected", thread_id = "guard-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(value) error_message <<- value,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = TRUE))
  )
  settled <- FALSE
  rejection <- NULL
  promises::then(handler_promise, function(value) {
    settled <<- TRUE
    NULL
  }, function(reason) {
    rejection <<- reason
    settled <<- TRUE
    NULL
  })
  for (index in seq_len(100L)) {
    later::run_now(0.01)
    if (settled) break
  }
  expect_true(settled)
  expect_null(rejection)
  expect_match(error_message, "close and reopen", ignore.case = TRUE)
  expect_false(done)
  expect_identical(client_creations, 0L)

  action_result <- NULL
  attr(handler, "action_handler")(
    "compact", "guard-thread",
    function(message, status, value = NULL) action_result <<- list(message, status)
  )
  expect_identical(action_result[[2L]], "error")
  expect_match(action_result[[1L]], "close and reopen", ignore.case = TRUE)

  model_result <- NULL
  attr(handler, "action_handler")(
    "model:sonnet", "guard-thread",
    function(message, status, value = NULL) model_result <<- list(message, status, value)
  )
  expect_identical(model_result[[2L]], "ok")
  expect_identical(model_result[[3L]], "sonnet")
  expect_match(model_result[[1L]], "close and reopen", ignore.case = TRUE)
  expect_identical(client_creations, 0L)

  expect_error(attr(handler, "warmup")("guard-thread"), "close and reopen", ignore.case = TRUE)

  attr(handler, "cleanup")()
  expect_true(attr(handler, "performance_snapshot")()$memory_guard$disposed)
})
