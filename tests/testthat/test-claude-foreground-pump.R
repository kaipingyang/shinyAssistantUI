foreground_pump_scheduler <- function() {
  state <- new.env(parent = emptyenv())
  state$queue <- list()
  state$max_pending <- 0L
  schedule <- function(callback, delay) {
    item <- new.env(parent = emptyenv())
    item$callback <- callback
    item$delay <- delay
    item$cancelled <- FALSE
    state$queue <- c(state$queue, list(item))
    state$max_pending <- max(state$max_pending, sum(vapply(
      state$queue, function(item) !isTRUE(item$cancelled), logical(1)
    )))
    function() item$cancelled <- TRUE
  }
  next_tick <- function() {
    state$queue <- Filter(function(item) !isTRUE(item$cancelled), state$queue)
    stopifnot(length(state$queue) == 1L)
    item <- state$queue[[1L]]
    state$queue <- list()
    if (!item$cancelled) item$callback()
    item
  }
  list(state = state, schedule = schedule, next_tick = next_tick)
}

foreground_pump_observe <- function(promise) {
  state <- new.env(parent = emptyenv())
  state$settled <- 0L
  state$error <- NULL
  promises::then(promise, function(value) {
    state$settled <- state$settled + 1L
    NULL
  }, function(error) {
    state$error <- error
    state$settled <- state$settled + 1L
    NULL
  })
  state
}

foreground_pump_drain <- function(until, loop = later::current_loop()) {
  deadline <- proc.time()[["elapsed"]] + 5
  while (!isTRUE(until())) {
    later::run_now(0.01, loop = loop)
    if (proc.time()[["elapsed"]] > deadline) {
      stop("Foreground pump promise did not settle")
    }
  }
}

foreground_pump_finalizer <- function(state) {
  force(state)
  function(value) state$collected <- TRUE
}

test_that("the production coroutine awaits one foreground completion pump", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  on.exit(attr(handler, "cleanup")(), add = TRUE)
  coroutine <- get("fn", envir = environment(handler), inherits = FALSE)
  code <- deparse(body(coroutine))
  expect_equal(sum(grepl("coro::await(.claude_foreground_pump(turn))", code,
                        fixed = TRUE)), 1L)
  expect_false(any(grepl("turn$pump()", code, fixed = TRUE)))
})

test_that("a pending usage probe does not retain the completed foreground turn", {
  skip_if_not_installed("ClaudeAgentSDK")
  state <- new.env(parent = emptyenv())
  state$done <- 0L
  state$collected <- FALSE
  state$pending <- NULL
  state$usage <- list()
  state$queue <- list(ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "pump-usage-session",
    result = "Complete.", total_cost_usd = 0.1, usage = list(input_tokens = 7L)
  ))
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(content) invisible(NULL)
  client$poll_messages <- function() {
    batch <- state$queue
    state$queue <- list()
    batch
  }
  client$get_context_usage_async <- function(timeout_ms = Inf,
                                              on_fulfilled = NULL,
                                              on_rejected = NULL) {
    state$pending <- list(resolve = on_fulfilled, reject = on_rejected)
    invisible(NULL)
  }
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .package = "shinyAssistantUI"
  )
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  on.exit(attr(handler, "cleanup")(), add = TRUE)
  noop <- function(...) invisible(NULL)
  callbacks <- list(
    thread_id = "pump-usage", attachments = list(),
    on_chunk = noop, on_done = function() state$done <- state$done + 1L,
    on_error = function(message) stop(message),
    on_tool_call = noop, on_tool_result = noop, on_thinking = noop,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) stop("Unexpected approval"),
    on_usage = function(cost, tokens, context = NULL, turns = NULL,
                        duration = NULL, model = NULL, window = NULL) {
      state$usage <- c(state$usage, list(list(
        cost_usd = cost, tokens = tokens, context_tokens = context,
        turns = turns, duration_ms = duration, model = model, context_window = window
      )))
    }
  )
  result <- foreground_pump_observe(local({
    payload <- new.env(parent = emptyenv())
    reg.finalizer(payload, foreground_pump_finalizer(state))
    do.call(handler, c(list(
      message = structure("Synthetic turn", retention_sentinel = payload)
    ), callbacks))
  }))
  foreground_pump_drain(function() result$settled == 1L)
  expect_null(result$error)
  expect_identical(state$done, 1L)
  expect_identical(attr(handler, "performance_snapshot")()$active_turns, 0L)
  expect_identical(attr(handler, "performance_snapshot")()$usage_probes_pending, 1L)
  expect_null(state$usage[[1L]]$context_tokens)
  expect_identical(state$usage[[1L]]$duration_ms, 1)
  invisible(gc(full = TRUE))
  expect_true(state$collected)

  state$pending$resolve(list(totalTokens = 17L, rawMaxTokens = 200000L))
  later::run_now(0)
  expect_identical(state$done, 1L)
  expect_length(state$usage, 2L)
  expect_identical(state$usage[[2L]]$tokens, 7)
  expect_identical(state$usage[[2L]]$context_tokens, 17)
  expect_identical(state$usage[[2L]]$duration_ms, 1)
  expect_identical(attr(handler, "performance_snapshot")()$active_turns, 0L)
  expect_identical(attr(handler, "performance_snapshot")()$usage_probes_pending, 0L)
})

test_that("usage snapshots keep the established callback field order", {
  received <- NULL
  publish <- .claude_usage_publisher(
    function(...) received <<- list(...), 0.1, 7, 1, 10, "fixture"
  )
  publish(17, 200000L)
  expect_identical(received, list(
    cost_usd = 0.1, tokens = 7, context_tokens = 17, turns = 1,
    duration_ms = 10, model = "fixture", context_window = 200000L
  ))
})

test_that("the pump keeps one timer, pauses for approval, and settles once", {
  timer <- foreground_pump_scheduler()
  statuses <- c("yield", "idle", "approval", "done")
  calls <- 0L
  resolve_approval <- NULL
  decision <- NULL
  turn <- list(
    pump = function() {
      calls <<- calls + 1L
      statuses[[calls]]
    },
    approval = function() promises::promise(function(resolve, reject) {
      resolve_approval <<- resolve
    }),
    decide = function(value) decision <<- value
  )
  result <- foreground_pump_observe(.claude_foreground_pump(turn, timer$schedule))
  first <- timer$next_tick()
  expect_equal(first$delay, 0)
  first$callback()
  expect_identical(calls, 1L)
  expect_equal(timer$next_tick()$delay, 0)
  expect_equal(timer$next_tick()$delay, 0.05)
  expect_length(timer$state$queue, 0L)
  expect_identical(calls, 3L)
  expect_identical(result$settled, 0L)

  resolve_approval(list(approved = TRUE))
  foreground_pump_drain(function() length(timer$state$queue) == 1L)
  expect_identical(decision, list(approved = TRUE))
  last <- timer$next_tick()
  expect_equal(last$delay, 0)
  foreground_pump_drain(function() result$settled == 1L)
  last$callback()
  later::run_now(0)
  expect_identical(result$settled, 1L)
  expect_null(result$error)
  expect_identical(calls, 4L)
  expect_identical(timer$state$max_pending, 1L)
  expect_length(timer$state$queue, 0L)
})

test_that("foreground pump failures reject once without continuing the timer", {
  for (stage in c("pump", "approval-call", "approval-reject", "decision", "invalid")) {
    timer <- foreground_pump_scheduler()
    calls <- 0L
    turn <- list(
      pump = function() {
        calls <<- calls + 1L
        if (stage == "pump") stop("Synthetic pump error")
        if (stage == "invalid") return("invalid")
        "approval"
      },
      approval = function() {
        if (stage == "approval-call") stop("Synthetic approval call error")
        if (stage == "approval-reject") {
          return(promises::promise_reject(simpleError("Synthetic approval rejection")))
        }
        promises::promise_resolve(list(approved = TRUE))
      },
      decide = function(value) stop("Synthetic decision error")
    )
    result <- foreground_pump_observe(.claude_foreground_pump(turn, timer$schedule))
    late <- timer$next_tick()$callback
    foreground_pump_drain(function() result$settled == 1L)
    expect_s3_class(result$error, "error")
    late()
    expect_identical(result$settled, 1L)
    expect_identical(calls, 1L)
    expect_length(timer$state$queue, 0L)
  }
})

test_that("foreground scheduler errors and invalid cancellation handles reject", {
  for (invalid in c(FALSE, TRUE)) {
    schedule <- function(callback, delay) {
      if (invalid) return(NULL)
      stop("Synthetic scheduler error")
    }
    calls <- 0L
    result <- foreground_pump_observe(.claude_foreground_pump(
      list(pump = function() {
        calls <<- calls + 1L
        "done"
      }), schedule
    ))
    foreground_pump_drain(function() result$settled == 1L)
    expect_s3_class(result$error, "error")
    expect_match(conditionMessage(result$error), "scheduler")
    expect_identical(calls, 0L)
  }
})

test_that("scheduled pump work and approval decisions restore the caller domain", {
  timer <- foreground_pump_scheduler()
  seen <- character()
  domain <- promises::new_promise_domain(wrapSync = function(expr) {
    withr::with_options(list(aui_pump_domain = "caller"), force(expr))
  })
  turn <- list(
    pump = function() {
      seen <<- c(seen, getOption("aui_pump_domain", "missing"))
      if (length(seen) == 1L) return("approval")
      "done"
    },
    approval = function() promises::promise_resolve(list(approved = TRUE)),
    decide = function(value) {
      seen <<- c(seen, getOption("aui_pump_domain", "missing"))
    }
  )
  promise <- promises::with_promise_domain(
    domain, .claude_foreground_pump(turn, timer$schedule)
  )
  result <- foreground_pump_observe(promise)
  timer$next_tick()
  foreground_pump_drain(function() length(timer$state$queue) == 1L)
  timer$next_tick()
  foreground_pump_drain(function() result$settled == 1L)
  expect_identical(seen, rep("caller", 3L))
  expect_null(getOption("aui_pump_domain"))
  expect_null(result$error)
})

test_that("the real foreground scheduler uses the caller later loop", {
  loop <- later::create_loop(parent = NULL)
  on.exit(later::destroy_loop(loop), add = TRUE)
  seen <- list()
  result <- later::with_loop(loop, foreground_pump_observe(
    .claude_foreground_pump(list(pump = function() {
      seen[[length(seen) + 1L]] <<- later::current_loop()
      if (length(seen) == 1L) return("yield")
      "done"
    }))
  ))
  later::run_now(0, loop = later::global_loop())
  expect_length(seen, 0L)
  foreground_pump_drain(function() result$settled == 1L, loop)
  expect_length(seen, 2L)
  expect_true(all(vapply(seen, identical, logical(1), loop)))
  expect_null(result$error)
})

test_that("settled pump callbacks release their turn on both success and rejection", {
  for (fail in c(FALSE, TRUE)) {
    timer <- foreground_pump_scheduler()
    state <- new.env(parent = emptyenv())
    state$collected <- FALSE
    turn <- local({
      payload <- new.env(parent = emptyenv())
      reg.finalizer(payload, foreground_pump_finalizer(state))
      list(pump = function() {
        stopifnot(is.environment(payload))
        if (fail) stop("Synthetic payload error")
        "done"
      })
    })
    result <- foreground_pump_observe(.claude_foreground_pump(turn, timer$schedule))
    rm(turn)
    late <- timer$next_tick()$callback
    foreground_pump_drain(function() result$settled == 1L)
    invisible(gc(full = TRUE))
    expect_true(state$collected)
    late()
    expect_identical(result$settled, 1L)
    expect_length(timer$state$queue, 0L)
  }
})

test_that("incompatible promises domain APIs fail explicitly rather than losing context", {
  local_mocked_bindings(
    current_promise_domain = function(unexpected) unexpected,
    .package = "promises"
  )
  expect_error(
    .claude_foreground_pump(list(pump = function() "done")),
    "promise domain"
  )
})

test_that("approval heartbeat keeps one owner timer and ignores an expired late decision", {
  timer <- foreground_pump_scheduler()
  calls <- polls <- decisions <- 0L
  resolve_approval <- NULL
  still_pending <- TRUE
  turn <- list(
    pump = function() {
      calls <<- calls + 1L
      if (calls == 1L) "approval" else "done"
    },
    approval = function() promises::promise(function(resolve, reject) {
      resolve_approval <<- resolve
    }),
    poll_approval = function() {
      polls <<- polls + 1L
      still_pending
    },
    decide = function(value) decisions <<- decisions + 1L
  )
  result <- foreground_pump_observe(.claude_foreground_pump(turn, timer$schedule))
  timer$next_tick()
  expect_equal(timer$next_tick()$delay, 1)
  expect_identical(polls, 1L)
  expect_identical(calls, 1L)
  still_pending <- FALSE
  timer$next_tick()
  timer$next_tick()
  foreground_pump_drain(function() result$settled == 1L)
  resolve_approval(list(approved = TRUE))
  later::run_now(0)
  expect_identical(decisions, 0L)
  expect_null(result$error)
  expect_identical(result$settled, 1L)
  expect_identical(timer$state$max_pending, 1L)
  expect_length(timer$state$queue, 0L)
})

test_that("a human decision cancels its pending heartbeat before resuming the pump", {
  timer <- foreground_pump_scheduler()
  calls <- 0L
  resolve_approval <- NULL
  decision <- NULL
  turn <- list(
    pump = function() {
      calls <<- calls + 1L
      if (calls == 1L) "approval" else "done"
    },
    approval = function() promises::promise(function(resolve, reject) {
      resolve_approval <<- resolve
    }),
    poll_approval = function() stop("Cancelled heartbeat should not run"),
    decide = function(value) decision <<- value
  )
  result <- foreground_pump_observe(.claude_foreground_pump(turn, timer$schedule))
  timer$next_tick()
  resolve_approval(list(approved = TRUE))
  foreground_pump_drain(function() !is.null(decision))
  expect_identical(decision, list(approved = TRUE))
  timer$next_tick()
  foreground_pump_drain(function() result$settled == 1L)
  expect_null(result$error)
  expect_identical(timer$state$max_pending, 1L)
  expect_length(timer$state$queue, 0L)
})
