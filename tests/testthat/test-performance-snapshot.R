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
