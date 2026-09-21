make_test_interrupt <- function(message = "simulated viewer stop") {
  structure(
    list(message = message, call = NULL),
    class = c("interrupt", "condition")
  )
}

test_that("addin gadget treats Viewer interrupt and cancellation as normal shutdown", {
  interrupt_runner <- function(...) stop(make_test_interrupt())
  cancel_runner <- function(...) stop("User cancel", call. = FALSE)
  error_runner <- function(...) stop("real startup failure", call. = FALSE)
  stop_on_cancel <- NULL
  normal_runner <- function(..., stopOnCancel = TRUE) {
    stop_on_cancel <<- stopOnCancel
    NULL
  }

  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = interrupt_runner))
  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = cancel_runner))
  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = normal_runner))
  expect_false(stop_on_cancel)
  expect_error(
    .run_claude_gadget(NULL, NULL, run_gadget = error_runner),
    "real startup failure"
  )
})

test_that("session cleanup absorbs interrupt conditions from process cleanup", {
  cleanup_calls <- 0L
  handler <- function(...) NULL
  attr(handler, "cleanup") <- function() {
    cleanup_calls <<- cleanup_calls + 1L
    stop(make_test_interrupt("processx wait interrupted"))
  }

  escaped <- FALSE
  tryCatch(
    shiny::testServer(function(input, output, session) {
      assistantUIServer("chat", handler = handler)
    }, {
      session$close()
    }),
    interrupt = function(e) escaped <<- TRUE
  )

  expect_false(escaped)
  expect_identical(cleanup_calls, 1L)
})


test_that("Claude client cleanup clears registry first, retries interrupt, and continues", {
  registry <- list()
  first_calls <- 0L
  second_calls <- 0L
  registry_was_empty <- logical()

  first <- new.env(parent = emptyenv())
  first$disconnect <- function() {
    first_calls <<- first_calls + 1L
    registry_was_empty <<- c(registry_was_empty, length(registry) == 0L)
    if (first_calls == 1L) stop(make_test_interrupt("first wait interrupted"))
    invisible(NULL)
  }
  second <- new.env(parent = emptyenv())
  second$disconnect <- function() {
    second_calls <<- second_calls + 1L
    registry_was_empty <<- c(registry_was_empty, length(registry) == 0L)
    invisible(NULL)
  }
  registry <- list(first = first, second = second)

  cleanup <- function() {
    .cleanup_claude_client_registry(
      get_clients = function() registry,
      clear_clients = function() registry <<- list()
    )
  }
  expect_no_condition(cleanup())
  expect_length(registry, 0L)
  expect_identical(first_calls, 2L)
  expect_identical(second_calls, 1L)
  expect_true(all(registry_was_empty))

  expect_no_condition(cleanup())
  expect_identical(first_calls, 2L)
  expect_identical(second_calls, 1L)
})

test_that("an interrupted connect unregisters and disconnects the partial client", {
  registry <- NULL
  disconnect_calls <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() stop(make_test_interrupt("connect interrupted"))
  client$disconnect <- function() {
    disconnect_calls <<- disconnect_calls + 1L
    invisible(NULL)
  }

  escaped <- FALSE
  tryCatch(
    .connect_registered_claude_client(
      client,
      register = function(x) registry <<- x,
      unregister = function(x) {
        if (identical(registry, x)) registry <<- NULL
      }
    ),
    interrupt = function(e) escaped <<- TRUE
  )

  expect_true(escaped)
  expect_null(registry)
  expect_identical(disconnect_calls, 1L)
})


test_that("owner-aware handlers detach one browser without global shutdown", {
  detached <- character()
  cleanup_calls <- 0L
  handler <- function(...) NULL
  attr(handler, "detach_ui_owner") <- function(ui_owner) {
    detached <<- c(detached, ui_owner)
    invisible(TRUE)
  }
  attr(handler, "cleanup") <- function() {
    cleanup_calls <<- cleanup_calls + 1L
    invisible(NULL)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$close()
  })

  expect_length(detached, 1L)
  expect_true(nzchar(detached[[1L]]))
  expect_identical(cleanup_calls, 0L)
})


test_that("Claude UI owner detach is idempotent and stale owners cannot clear replacements", {
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  attach <- attr(handler, "attach_ui_owner")
  detach <- attr(handler, "detach_ui_owner")
  snapshot <- attr(handler, "ui_owner_snapshot")

  expect_true(is.function(attach))
  expect_true(is.function(detach))
  expect_true(is.function(snapshot))
  expect_true(attach("thread-1", "owner-a", list(on_messages = function(...) NULL)))
  first <- snapshot("thread-1")
  expect_identical(first$owner, "owner-a")

  expect_true(attach("thread-1", "owner-b", list(on_messages = function(...) NULL)))
  expect_false(detach("owner-a"))
  second <- snapshot("thread-1")
  expect_identical(second$owner, "owner-b")
  expect_true(second$has_callbacks)

  expect_true(detach("owner-b"))
  expect_false(detach("owner-b"))
  final <- snapshot("thread-1")
  expect_null(final$owner)
  expect_false(final$has_callbacks)
  attr(handler, "cleanup")()
})


test_that("Claude owner detach releases callback-captured large payloads", {
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  attach <- attr(handler, "attach_ui_owner")
  detach <- attr(handler, "detach_ui_owner")
  finalized <- FALSE

  callback <- local({
    holder <- new.env(parent = emptyenv())
    holder$payload <- raw(8 * 1024 * 1024)
    reg.finalizer(holder, function(environment) finalized <<- TRUE, onexit = FALSE)
    function(...) length(holder$payload)
  })
  expect_true(attach("large-thread", "large-owner", list(on_messages = callback)))
  rm(callback)
  expect_true(detach("large-owner"))
  for (iteration in seq_len(3L)) gc(full = TRUE)

  expect_true(finalized)
  state <- attr(handler, "ui_owner_snapshot")("large-thread")
  expect_null(state$owner)
  expect_false(state$has_callbacks)
  attr(handler, "cleanup")()
})


test_that("owner dispatch wrappers reject stale generations after handoff", {
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  withr::defer(attr(handler, "cleanup")())
  attach <- attr(handler, "attach_ui_owner")
  dispatch <- attr(handler, ".ui_owner_dispatch")
  calls <- character()

  expect_true(attach("thread-generation", "owner-a", list(
    on_messages = function(...) calls <<- c(calls, "a")
  )))
  stale_dispatch <- dispatch("thread-generation", "on_messages")
  expect_true(is.function(stale_dispatch))
  expect_true(attach("thread-generation", "owner-b", list(
    on_messages = function(...) calls <<- c(calls, "b")
  )))

  stale_dispatch(messages = list(), revision = 1L, after_run_id = NULL)
  expect_length(calls, 0L)
  dispatch("thread-generation", "on_messages")(
    messages = list(), revision = 2L, after_run_id = NULL
  )
  expect_identical(calls, "b")
})


test_that("detached proactive publication retains only a bounded refresh marker", {
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  withr::defer(attr(handler, "cleanup")())
  attach <- attr(handler, "attach_ui_owner")
  detach <- attr(handler, "detach_ui_owner")
  publish <- attr(handler, ".publish_persistent_messages")
  snapshot <- attr(handler, "ui_owner_snapshot")

  expect_true(attach("thread-marker", "owner-marker", list(
    on_messages = function(...) NULL
  )))
  expect_true(detach("owner-marker"))
  publish(
    "thread-marker",
    messages = list(list(content = raw(8 * 1024 * 1024))),
    revision = 9L,
    after_run_id = "run-old"
  )

  state <- snapshot("thread-marker")
  expect_true(state$pending_refresh)
  expect_false(state$pending_has_messages)
  expect_lt(state$pending_bytes, 4096)
})


test_that("history-only reconnect explicitly attaches its browser owner", {
  attached <- list()
  handler <- function(...) NULL
  attr(handler, "attach_ui_owner") <- function(thread_id, ui_owner, callbacks, ...) {
    attached[[length(attached) + 1L]] <<- list(
      thread_id = thread_id,
      ui_owner = ui_owner,
      callbacks = callbacks,
      args = list(...)
    )
    TRUE
  }
  attr(handler, "detach_ui_owner") <- function(ui_owner) TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      on_session_load = function(send_thread, ...) send_thread(list())
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session",
      sessionId = "session-history",
      threadId = "thread-history",
      requestId = "request-history",
      project = tempdir()
    ))
    session$flushReact()
  })

  expect_length(attached, 1L)
  expect_identical(attached[[1L]]$thread_id, "thread-history")
  expect_true(nzchar(attached[[1L]]$ui_owner))
  expect_true(is.function(attached[[1L]]$callbacks$on_proactive_messages))
  expect_true(isTRUE(attached[[1L]]$args$history_only))
})


test_that("addin app-global handler cleanup is guarded to run exactly once", {
  cleanup_calls <- 0L
  handler <- function(...) NULL
  attr(handler, "cleanup") <- function() cleanup_calls <<- cleanup_calls + 1L
  cleanup <- .claude_once_handler_cleanup(handler)

  expect_true(cleanup())
  expect_false(cleanup())
  expect_false(cleanup())
  expect_identical(cleanup_calls, 1L)
})


test_that("an active Claude turn owner cannot be replaced by another browser", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  poll_count <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$get_server_info <- function() list()
  client$approve_tool <- function(...) invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    poll_count <<- poll_count + 1L
    if (poll_count == 1L) {
      return(list(ClaudeAgentSDK::PermissionRequestMessage(
        request_id = "request-owner",
        tool_name = "Write",
        tool_input = list(file_path = "owner-test.txt", content = "test"),
        tool_use_id = "tool-owner"
      )))
    }
    if (poll_count == 2L) {
      return(list(ClaudeAgentSDK::ResultMessage(
        subtype = "success", duration_ms = 1, duration_api_ms = 1,
        is_error = FALSE, num_turns = 1, session_id = "session-owner",
        result = "done"
      )))
    }
    list()
  }
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_idle_start_delay_seconds = function() 3600
  )

  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  withr::defer(attr(handler, "cleanup")())
  approval_resolve <- NULL
  settled <- FALSE
  promise <- handler(
    message = "test active owner",
    thread_id = "thread-active-owner",
    ui_owner = "owner-a",
    attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) NULL,
    on_error = function(...) NULL,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise(function(resolve, reject) {
      approval_resolve <<- resolve
    })
  )
  promises::then(promise, function(value) settled <<- TRUE)
  for (iteration in seq_len(100L)) {
    later::run_now(0.01)
    if (is.function(approval_resolve)) break
  }
  expect_true(is.function(approval_resolve))
  expect_false(attr(handler, "attach_ui_owner")(
    "thread-active-owner", "owner-b", list(on_messages = function(...) NULL)
  ))

  approval_resolve(list(approved = FALSE))
  for (iteration in seq_len(200L)) {
    later::run_now(0.01)
    if (isTRUE(settled)) break
  }
  expect_true(settled)
  expect_true(attr(handler, "attach_ui_owner")(
    "thread-active-owner", "owner-b", list(on_messages = function(...) NULL)
  ))
})


test_that("assistantUIServer owns one consolidated session finalizer", {
  source <- paste(deparse(body(assistantUIServer), width.cutoff = 500L), collapse = "\n")
  matches <- gregexpr("session$onSessionEnded", source, fixed = TRUE)[[1L]]
  count <- if (identical(matches[[1L]], -1L)) 0L else length(matches)

  expect_identical(count, 1L)
  expect_match(source, "cancel_pending_approvals()", fixed = TRUE)
  expect_match(source, "lazy_tool_results$cleanup()", fixed = TRUE)
  expect_match(source, "run_scheduler$close()", fixed = TRUE)
  expect_match(source, "cleanup_start", fixed = TRUE)
  expect_match(source, "cleanup_end", fixed = TRUE)
})


test_that("Claude memory diagnostics are owner-bound and detach makes them inert", {
  handler <- make_claude_handler(
    session_map_path = tempfile(fileext = ".rds"),
    memory_guard_config = .memory_guard_default_config(),
    memory_sampler = function() list(
      available = TRUE, source = "fixture", pss_bytes = 80, rss_bytes = 90,
      private_dirty_bytes = 70, anonymous_bytes = 60,
      cgroup_current_bytes = 200, cgroup_max_bytes = 1000,
      cgroup_events = list(high = 3, max = 2, oom = 1, oom_kill = 0)
    )
  )
  withr::defer(attr(handler, "cleanup")())
  observed <- list()
  attach <- attr(handler, "attach_ui_owner")
  detach <- attr(handler, "detach_ui_owner")
  observe_memory <- attr(handler, ".memory_guard_observe")

  expect_true(attach("diag-thread", "diag-owner", list(
    on_diagnostics = function(event, metrics) {
      observed[[length(observed) + 1L]] <<- list(event = event, metrics = metrics)
    }
  )))
  expect_true(observe_memory())
  expect_true(any(vapply(observed, function(x) x$event == "memory_sample", logical(1))))
  memory <- Filter(function(x) x$event == "memory_sample", observed)[[1L]]
  expect_true(any(c("pss_bytes", "rss_bytes") %in% names(memory$metrics)))
  expect_identical(memory$metrics$guard_state, "normal")
  expect_identical(memory$metrics$soft_pss_bytes, .memory_guard_gib(1))
  expect_identical(memory$metrics$hard_pss_bytes, .memory_guard_gib(2))
  expect_identical(memory$metrics$soft_rss_bytes, .memory_guard_gib(1.25))
  expect_identical(memory$metrics$hard_rss_bytes, .memory_guard_gib(2.25))

  before <- length(observed)
  expect_true(detach("diag-owner"))
  expect_true(observe_memory())
  expect_identical(memory$metrics$private_dirty_bytes, 70)
  expect_identical(memory$metrics$anonymous_bytes, 60)
  expect_identical(memory$metrics$cgroup_high_events, 3)
  expect_identical(memory$metrics$cgroup_max_events, 2)
  expect_identical(memory$metrics$cgroup_oom_events, 1)
  expect_identical(memory$metrics$cgroup_oom_kill_events, 0)
  expect_identical(memory$metrics$r_heap_after_gc_bytes, 0)
  expect_identical(memory$metrics$guard_gc_count, 0)
  expect_identical(memory$metrics$sdk_client_count, 0)
  expect_identical(memory$metrics$sdk_consumer_count, 0)
  expect_identical(memory$metrics$sdk_route_count, 1)
  expect_identical(memory$metrics$sdk_messages_seen, 0)
  expect_identical(memory$metrics$sdk_buffered_message_count, 0)
  expect_identical(memory$metrics$sdk_waiter_count, 0)
  expect_identical(memory$metrics$sdk_usage_probe_pending_count, 0)
  expect_identical(memory$metrics$sdk_message_bytes_seen, 0)
  expect_identical(memory$metrics$sdk_max_batch_bytes, 0)
  expect_identical(memory$metrics$active_turn_count, 0)
  expect_identical(length(observed), before)
})
