long_task_message <- function(kind, ...) structure(list(...), class = kind)

long_task_harness <- function(..., permission = NULL, observe = NULL) {
  state <- new.env(parent = emptyenv())
  state$clock <- 0
  state$incoming <- list()
  state$scheduled <- list()
  state$polls <- state$interrupts <- state$denied <- state$results <- 0L
  state$errors <- character()
  state$events <- list()
  state$interrupt_result <- NULL
  state$alive <- TRUE
  state$retired <- FALSE
  state$poll_error <- NULL
  schedule <- function(callback, delay) {
    job <- new.env(parent = emptyenv())
    job$active <- TRUE
    job$callback <- callback
    job$delay <- delay
    state$scheduled[[length(state$scheduled) + 1L]] <- job
    function() job$active <- FALSE
  }
  tick <- function(at) {
    state$clock <- at
    while (length(state$scheduled)) {
      job <- state$scheduled[[1L]]
      state$scheduled <- state$scheduled[-1L]
      if (!job$active) next
      job$active <- FALSE
      job$callback()
      return(TRUE)
    }
    FALSE
  }
  push <- function(...) state$incoming <- c(state$incoming, list(...))
  args <- list(
    poll_messages = function() {
      state$polls <- state$polls + 1L
      if (!is.null(state$poll_error)) stop(state$poll_error)
      batch <- state$incoming
      state$incoming <- list()
      batch
    },
    schedule = schedule, now = function() state$clock,
    on_idle_event = function(message) {
      state$events <- c(state$events, list(message))
      if (is.function(observe)) observe(message)
    },
    on_idle_result = function(message, on_complete) {
      state$results <- state$results + 1L
      on_complete()
    },
    on_idle_failure = function(reason, on_complete, ...) {
      state$errors <- c(state$errors, conditionMessage(reason))
      on_complete()
    },
    handle_idle_permission = permission,
    deny_idle_permission = function(message) state$denied <- state$denied + 1L,
    interrupt = function() {
      state$interrupts <- state$interrupts + 1L
      if (!is.null(state$interrupt_result)) {
        state$incoming <- c(state$incoming, list(state$interrupt_result))
      }
    }
  )
  args <- utils::modifyList(args, list(...))
  coordinator <- do.call(.new_claude_consumer_coordinator, args)
  list(state = state, coordinator = coordinator, tick = tick, push = push,
       schedule = schedule)
}

test_that("healthy background work is not interrupted by elapsed time or silence", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  for (time in c(0, 119, 121, 900)) {
    h$push(long_task_message("AssistantMessage", content = "progress"))
    expect_true(h$tick(time))
  }
  expect_identical(h$state$interrupts, 0L)
  expect_length(h$state$errors, 0L)
  expect_true(h$tick(1800))
  h$push(long_task_message("ResultMessage", session_id = "long-task"))
  expect_true(h$tick(1801))
  expect_identical(h$state$results, 1L)
  expect_false(h$coordinator$is_busy())
})

test_that("a queued Result is consumed even after a long event-loop pause", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("AssistantMessage"))
  h$tick(0)
  h$push(long_task_message("ResultMessage", session_id = "ready-result"))
  h$tick(121)
  expect_identical(h$state$results, 1L)
  expect_identical(h$state$interrupts, 0L)
})

test_that("parented task messages do not reserve a top-level Result owner", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(
    long_task_message("StreamEvent", parent_tool_use_id = "agent-parent"),
    long_task_message("AssistantMessage", parent_tool_use_id = "agent-parent"),
    long_task_message("TaskNotificationMessage", task_id = "agent-child", status = "completed")
  )
  for (step in seq_len(8L)) {
    h$tick(0)
    if (length(h$state$events) == 3L) break
  }
  expect_false(h$coordinator$is_busy())
  acquired <- FALSE
  h$coordinator$acquire("foreground:after-child", function() acquired <<- TRUE)
  expect_true(acquired)
  expect_identical(h$state$interrupts, 0L)
})

test_that("a long background approval is not an expired turn on resume", {
  resume <- NULL
  h <- long_task_harness(permission = function(message, on_complete, on_failure) {
    resume <<- on_complete
    TRUE
  })
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "approval"))
  h$tick(0)
  expect_true(is.function(resume))
  h$state$clock <- 600
  resume()
  h$push(long_task_message("ResultMessage", session_id = "approved"))
  h$tick(600)
  expect_identical(h$state$interrupts, 0L)
  expect_identical(h$state$results, 1L)
})

test_that("an interrupted idle turn drains its Result before granting the next owner", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$state$interrupt_result <- long_task_message(
    "ResultMessage", session_id = "same-session", uuid = "old-error", is_error = TRUE
  )
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "unowned"))
  h$tick(0)
  acquired <- FALSE
  h$coordinator$acquire("foreground:new", function() acquired <<- TRUE)
  expect_false(acquired)
  expect_true(h$tick(1))
  expect_true(acquired)
  expect_null(h$coordinator$poll_one("foreground:new"))
  expect_identical(h$state$interrupts, 1L)
})

test_that("background reception resumes after a drained idle failure", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$state$interrupt_result <- long_task_message("ResultMessage", session_id = "same-session")
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "unowned"))
  h$tick(0)
  expect_true(h$tick(1))
  h$push(long_task_message("TaskNotificationMessage", task_id = "late", status = "completed"))
  expect_true(h$tick(2))
  expect_true(any(vapply(h$state$events, function(message) {
    identical(message$task_id, "late")
  }, logical(1))))
})

test_that("memory admission does not suppress notifications for existing tasks", {
  h <- long_task_harness(can_open_idle = function() FALSE)
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("TaskNotificationMessage", task_id = "existing", status = "completed"))
  h$tick(0)
  expect_identical(h$state$polls, 1L)
  expect_length(h$state$events, 1L)
  expect_identical(h$state$interrupts, 0L)
})

test_that("background ownership follows structured parent calls but not unknown tasks", {
  tracker <- .new_claude_background_task_ownership()
  tracker$observe(long_task_message("StreamEvent", event = list(
    type = "content_block_start",
    content_block = list(type = "tool_use", id = "parent-call", name = "Agent")
  )), foreground = TRUE)
  tracker$observe(long_task_message(
    "TaskStartedMessage", task_id = "parent-task", tool_use_id = "parent-call"
  ), foreground = TRUE)
  tracker$observe(long_task_message("StreamEvent",
    parent_tool_use_id = "parent-call", event = list(
      type = "content_block_start",
      content_block = list(type = "tool_use", id = "child-call", name = "Agent")
    )
  ), foreground = FALSE)
  tracker$observe(long_task_message(
    "TaskStartedMessage", task_id = "child-task", tool_use_id = "child-call"
  ), foreground = FALSE)
  expect_true(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "child-task")))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "unowned-task")))
  tracker$observe(long_task_message("TaskNotificationMessage", task_id = "child-task",
                                    status = "completed"))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "child-task")))
})

test_that("late authoritative history is retried without completing the original waiter twice", {
  h <- long_task_harness()
  snapshot <- list(list(id = "old", content = "before"))
  publications <- list()
  completions <- logical()
  reconciler <- .new_claude_transcript_reconciler(
    read_snapshot = function(...) snapshot,
    publish = function(thread_id, messages, revision, after_run_id) {
      publications[[length(publications) + 1L]] <<- messages
    },
    schedule = h$schedule, now = function() h$state$clock
  )
  on.exit(reconciler$invalidate(), add = TRUE)
  reconciler$baseline("thread", "session", "/synthetic")
  reconciler$reconcile(
    "thread", "session", "/synthetic", "run-1", must_advance = TRUE,
    on_complete = function(ok, reason = NULL) completions <<- c(completions, ok)
  )
  h$tick(0.1)
  h$tick(1.9)
  h$tick(2.1)
  expect_length(completions, 1L)
  snapshot <- list(list(id = "new", content = "late answer"))
  expect_true(h$tick(3))
  h$tick(3.2)
  expect_length(publications, 1L)
  if (length(publications)) expect_identical(publications[[1L]], snapshot)
  expect_length(completions, 1L)
})

test_that("unconfirmed interrupt retires the queue and rejects rather than grants waiters", {
  retired <- 0L
  h <- long_task_harness(retire = function(reason) retired <<- retired + 1L)
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "unowned"))
  h$tick(0)
  acquired <- FALSE
  error <- NULL
  h$coordinator$acquire("foreground:blocked", function() acquired <<- TRUE,
                        function(reason) error <<- reason)
  h$tick(11)
  expect_identical(retired, 1L)
  expect_false(acquired)
  expect_s3_class(error, "error")
  expect_true(h$coordinator$metrics()$retired)
  expect_false(h$tick(12))
})

test_that("a cancelled consumer waiter is never granted after the old Result", {
  h <- long_task_harness()
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("AssistantMessage"))
  h$tick(0)
  acquired <- FALSE
  error <- NULL
  cancel <- h$coordinator$acquire("foreground:cancelled", function() acquired <<- TRUE,
                                 function(reason) error <<- reason)
  expect_true(cancel())
  expect_false(cancel())
  h$push(long_task_message("ResultMessage", session_id = "previous"))
  h$tick(1)
  expect_false(acquired)
  expect_s3_class(error, "claude_consumer_cancelled")
  expect_identical(h$coordinator$metrics()$waiters, 0L)
})

test_that("approval polling dispatches task metadata but defers conversation frames", {
  resume <- NULL
  expired <- 0L
  h <- long_task_harness(
    is_alive = function() TRUE,
    permission = function(message, on_complete, on_failure) {
      resume <<- on_complete
      list(cancel = function(reason) expired <<- expired + 1L,
           is_pending = function() TRUE)
    }
  )
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "approval"))
  h$tick(0)
  h$push(
    long_task_message("AssistantMessage", content = "defer until decision"),
    long_task_message("TaskProgressMessage", task_id = "active", status = "running")
  )
  expect_true(h$tick(1))
  expect_identical(h$state$polls, 2L)
  expect_identical(h$state$denied, 0L)
  expect_identical(expired, 0L)
  expect_length(h$state$events, 1L)
  if (length(h$state$events)) expect_s3_class(h$state$events[[1L]], "TaskProgressMessage")
  expect_true(resume())
  h$push(long_task_message("ResultMessage", session_id = "approved"))
  for (time in 2:4) h$tick(time)
  expect_identical(h$state$results, 1L)
  expect_true(any(vapply(h$state$events, inherits, logical(1), "AssistantMessage")))
})

test_that("a terminal arriving during approval expires the old decision and preserves its tail", {
  resume <- NULL
  expired <- 0L
  h <- long_task_harness(
    is_alive = function() TRUE,
    permission = function(message, on_complete, on_failure) {
      resume <<- on_complete
      list(cancel = function(reason) expired <<- expired + 1L,
           is_pending = function() TRUE)
    }
  )
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("PermissionRequestMessage", request_id = "approval"))
  h$tick(0)
  h$push(long_task_message("ResultMessage", session_id = "ended", is_error = TRUE))
  h$tick(1)
  h$state$poll_error <- simpleError("EOF after terminal")
  h$tick(2)
  expect_identical(expired, 1L)
  expect_identical(h$state$results, 1L)
  expect_false(resume())
  expect_identical(h$state$interrupts, 0L)
})

test_that("terminated tasks revoke tool-id ownership and cannot be reopened by replay", {
  tracker <- .new_claude_background_task_ownership()
  opener <- long_task_message("AssistantMessage", content = list(
    list(type = "tool_use", id = "agent-call", name = "Agent")
  ))
  task <- long_task_message("TaskStartedMessage", task_id = "agent", tool_use_id = "agent-call")
  tracker$observe(opener, foreground = TRUE)
  tracker$observe(task, foreground = TRUE)
  tracker$observe(long_task_message("AssistantMessage", parent_tool_use_id = "agent-call",
    content = list(list(type = "tool_use", id = "child-call", name = "Bash"))))
  expect_true(tracker$owns(long_task_message("PermissionRequestMessage", tool_use_id = "child-call")))
  tracker$observe(long_task_message("TaskNotificationMessage", task_id = "agent", status = "completed"))
  tracker$observe(opener)
  tracker$observe(task)
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", tool_use_id = "agent-call")))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", tool_use_id = "child-call")))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "agent")))
  expect_length(tracker$active_ids(), 0L)
})

test_that("a delayed TaskStarted may link to an ended foreground call without trusting strangers", {
  tracker <- .new_claude_background_task_ownership()
  tracker$observe(long_task_message("AssistantMessage", content = list(
    list(type = "tool_use", id = "background-call", name = "Agent")
  )), foreground = TRUE)
  tracker$observe(long_task_message("ResultMessage"))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", tool_use_id = "background-call")))
  tracker$observe(long_task_message("TaskStartedMessage", task_id = "late-owned",
                                  tool_use_id = "background-call"))
  expect_true(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "late-owned")))
  tracker$observe(long_task_message("TaskStartedMessage", task_id = "late-unknown",
                                  tool_use_id = "unknown-call"))
  expect_false(tracker$owns(long_task_message("PermissionRequestMessage", agent_id = "late-unknown")))
})

long_handler_fixture <- function(.env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$queue <- list()
  state$done <- state$disconnected <- state$interrupts <- state$approval_cancelled <- 0L
  state$sent <- state$approved <- state$denied <- state$errors <- character()
  state$tool_results <- state$tasks <- state$statuses <- list()
  state$transcript <- state$histories <- state$history_run_ids <- list()
  state$history_reads <- 0L
  state$decision <- state$stop_ack <- NULL
  state$client <- NULL
  testthat::local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) {
      state$options <- options
      client <- new.env(parent = emptyenv())
      client$alive <- TRUE
      client$connect <- function() invisible(NULL)
      client$is_alive <- function() client$alive
      client$disconnect <- function() {
        client$alive <- FALSE
        state$disconnected <- state$disconnected + 1L
      }
      client$send <- function(content) state$sent <- c(state$sent, as.character(content))
      client$get_server_info <- function() list()
      client$interrupt <- function() state$interrupts <- state$interrupts + 1L
      client$approve_tool <- function(request_id, ...) state$approved <- c(state$approved, request_id)
      client$deny_tool <- function(request_id, ...) state$denied <- c(state$denied, request_id)
      client$stop_task_async <- function(task_id, timeout_ms, on_fulfilled, on_rejected) {
        state$stop_ack <- on_fulfilled
      }
      client$poll_messages <- function() {
        if (is.function(state$stop_ack)) {
          ack <- state$stop_ack
          state$stop_ack <- NULL
          ack(list())
        }
        value <- state$queue
        state$queue <- list()
        if (!length(value) && !client$alive) stop("Synthetic CLI connection closed")
        value
      }
      state$client <- client
      client
    },
    .get_claude_session_messages = function(...) {
      state$history_reads <- state$history_reads + 1L
      state$transcript
    },
    .claude_msgs_to_thread = function(messages, ...) messages,
    .claude_drain_timeout_seconds = function() 0.01,
    .claude_compact_timeout_seconds = function() 0.01,
    .package = "shinyAssistantUI", .env = .env
  )
  withr::local_options(list(shinyAssistantUI.claude_idle_start_delay = 0), .local_envir = .env)
  handler <- make_claude_handler(
    options = list(permission_mode = "default"),
    session_map_path = tempfile(fileext = ".rds")
  )
  withr::defer(attr(handler, "cleanup")(), envir = .env)
  callbacks <- list(
    thread_id = "long-handler", run_id = "run-long", attachments = list(),
    on_chunk = function(...) invisible(NULL),
    on_done = function(...) state$done <- state$done + 1L,
    on_error = function(message) state$errors <- c(state$errors, message),
    on_tool_call = function(...) invisible(NULL),
    on_tool_result = function(...) state$tool_results <- c(state$tool_results, list(list(...))),
    on_thinking = function(...) invisible(NULL),
    on_task = function(...) state$tasks <- c(state$tasks, list(list(...))),
    on_proactive_task = function(...) state$tasks <- c(state$tasks, list(list(...))),
    on_proactive_status = function(...) state$statuses <- c(state$statuses, list(list(...))),
    on_proactive_messages = function(messages, revision, after_run_id = NULL, ...) {
      state$histories <- c(state$histories, list(messages))
      state$history_run_ids <- c(state$history_run_ids, list(after_run_id))
    },
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) {
      promise <- promises::promise(function(resolve, reject) state$decision <- resolve)
      attr(promise, "cancel") <- function() {
        state$approval_cancelled <- state$approval_cancelled + 1L
        state$decision(list(approved = FALSE, expired = TRUE))
      }
      promise
    }
  )
  list(
    state = state, handler = handler, callbacks = callbacks,
    start = function(message = "synthetic", ...) {
      do.call(handler, c(list(message = message), utils::modifyList(callbacks, list(...))))
    },
    wait = function(predicate, timeout = 2.5) {
      until <- Sys.time() + timeout
      while (!isTRUE(predicate()) && Sys.time() < until) later::run_now(0.01)
      isTRUE(predicate())
    },
    result = function() long_task_message(
      "ResultMessage", session_id = "synthetic-long", is_error = FALSE,
      result = "Synthetic completion", usage = list()
    )
  )
}

test_that("foreground approval receives Stop ACK and expires on terminal without a late approval", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "agent", tool_use_id = "tool"),
    long_task_message("PermissionRequestMessage", request_id = "permission",
                      agent_id = "agent", tool_use_id = "tool", tool_name = "Bash",
                      tool_input = list(command = "echo synthetic"))
  )
  f$start()
  expect_true(f$wait(function() is.function(f$state$decision)))
  decision <- f$state$decision
  action <- NULL
  attr(f$handler, "action_handler")("stoptask:agent", "long-handler",
    function(message, status, value = NULL) action <<- list(message = message, status = status))
  expect_true(f$wait(function() !is.null(action)))
  expect_identical(action$status, "ok")
  f$state$queue <- list(
    long_task_message("TaskNotificationMessage", task_id = "agent", status = "stopped"),
    f$result()
  )
  expect_true(f$wait(function() f$state$done > 0L || length(f$state$errors) > 0L))
  expect_identical(f$state$approval_cancelled, 1L)
  decision(list(approved = TRUE))
  later::run_now(0)
  expect_length(f$state$approved, 0L)
  expect_identical(f$state$done, 1L)
})

test_that("a dead process during foreground approval settles and removes the old decision", {
  f <- long_handler_fixture()
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "permission", tool_use_id = "tool",
    tool_name = "Bash", tool_input = list(command = "echo synthetic")
  ))
  f$start()
  expect_true(f$wait(function() is.function(f$state$decision)))
  f$state$client$alive <- FALSE
  expect_true(f$wait(function() length(f$state$errors) > 0L))
  expect_match(f$state$errors[[1L]], "closed", fixed = TRUE)
  expect_identical(f$state$approval_cancelled, 1L)
  expect_identical(f$state$disconnected, 1L)
  expect_identical(attr(f$handler, "performance_snapshot")()$active_turns, 0L)
})

test_that("compact timeout retires its unconfirmed connection before another turn", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  statuses <- character()
  attr(f$handler, "action_handler")("compact", "long-handler",
    function(message, status, value = NULL) statuses <<- c(statuses, status))
  expect_true(f$wait(function() "error" %in% statuses))
  expect_identical(f$state$disconnected, 1L)
  expect_identical(attr(f$handler, "performance_snapshot")()$connected_clients, 0L)
})

test_that("global handler cleanup disconnects an open idle turn instead of waiting forever", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message("AssistantMessage", content = list()))
  expect_true(f$wait(function() {
    isTRUE(attr(f$handler, "performance_snapshot")()$threads[[1L]]$coordinator$idle_open)
  }))
  attr(f$handler, "cleanup")()
  expect_identical(f$state$disconnected, 1L)
  expect_identical(attr(f$handler, "performance_snapshot")()$connected_clients, 0L)
  expect_identical(attr(f$handler, "performance_snapshot")()$coordinators, 0L)
})

test_that("connection option resets wait for metadata-only background tasks to finish", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  attr(f$handler, "action_handler")("thinking:adaptive", "long-handler",
    function(message, status, value = NULL) {
      expect_identical(status, "ok")
    })
  later::run_now(0)
  expect_identical(f$state$disconnected, 0L)
  f$state$queue <- list(long_task_message(
    "TaskNotificationMessage", task_id = "background", status = "completed"
  ))
  expect_true(f$wait(function() f$state$disconnected == 1L))
})

test_that("interrupt action joins the foreground drain instead of only sending a raw control", {
  f <- long_handler_fixture()
  f$start()
  expect_true(f$wait(function() length(f$state$sent) == 1L))
  attr(f$handler, "action_handler")("interrupt", "long-handler", function(...) NULL)
  expect_true(f$wait(function() f$state$done > 0L || length(f$state$errors) > 0L))
  expect_identical(f$state$interrupts, 1L)
  expect_identical(f$state$disconnected, 1L)
  expect_identical(attr(f$handler, "performance_snapshot")()$active_turns, 0L)
})

test_that("background approval receives controls and cannot approve after its task stops", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "background-permission",
    agent_id = "background", tool_use_id = "task-call", tool_name = "Bash",
    tool_input = list(command = "echo synthetic")
  ))
  expect_true(f$wait(function() is.function(f$state$decision)))
  decision <- f$state$decision
  attr(f$handler, "action_handler")("stoptask:background", "long-handler",
    function(message, status, value = NULL) {
      expect_identical(status, "ok")
    })
  f$state$queue <- list(long_task_message(
    "TaskNotificationMessage", task_id = "background", status = "stopped"
  ))
  expect_true(f$wait(function() f$state$approval_cancelled == 1L))
  expect_null(f$state$stop_ack)
  decision(list(approved = TRUE))
  later::run_now(0)
  expect_length(f$state$approved, 0L)
  expect_identical(f$state$interrupts, 0L)
})

test_that("handler cleanup settles a foreground waiter blocked behind background work", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message("AssistantMessage", content = list()))
  expect_true(f$wait(function() {
    isTRUE(attr(f$handler, "performance_snapshot")()$threads[[1L]]$coordinator$idle_open)
  }))
  settled <- FALSE
  promises::then(
    f$start("waiting", run_id = "run-waiting"),
    function(value) settled <<- TRUE, function(error) settled <<- TRUE
  )
  expect_true(f$wait(function() {
    identical(attr(f$handler, "performance_snapshot")()$threads[[1L]]$coordinator$waiters, 1L)
  }))
  attr(f$handler, "cleanup")()
  expect_true(f$wait(function() settled))
  expect_identical(length(f$state$sent), 1L)
  expect_identical(f$state$disconnected, 1L)
})

test_that("a failed write does not label old history as the failed request's authoritative answer", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  reads <- f$state$history_reads
  f$state$client$send <- function(content) stop("Synthetic write failed")
  f$start("Unsent local question", run_id = "run-unsent")
  expect_true(f$wait(function() length(f$state$errors) > 0L))
  expect_false(f$wait(function() f$state$history_reads > reads, timeout = 0.25))
  expect_identical(f$state$history_reads, reads)
  expect_identical(f$state$disconnected, 1L)
})

test_that("an idle error Result remains visible after successful history reconciliation", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "ResultMessage", session_id = "synthetic-long", is_error = TRUE,
    errors = list("Synthetic background failure"), result = "Partial work"
  ))
  expect_true(f$wait(function() any(vapply(f$state$statuses, function(status) {
    any(grepl("Synthetic background failure", unlist(status), fixed = TRUE))
  }, logical(1)))))
  expect_length(f$state$errors, 0L)
  expect_identical(f$state$done, 1L)
})

test_that("terminal history watch catches a reply written after an already changed user-only snapshot", {
  h <- long_task_harness()
  snapshot <- list(list(id = "old", role = "assistant", content = "before"))
  published <- list()
  completed <- 0L
  collected <- FALSE
  finalizer <- function(value) collected <<- TRUE
  callback <- local({
    payload <- new.env(parent = emptyenv())
    reg.finalizer(payload, finalizer)
    function(ok, reason = NULL) {
      stopifnot(is.environment(payload))
      expect_true(ok)
      completed <<- completed + 1L
    }
  })
  reconciler <- .new_claude_transcript_reconciler(
    read_snapshot = function(...) snapshot,
    publish = function(thread_id, messages, revision, after_run_id) {
      published[[length(published) + 1L]] <<- messages
    },
    schedule = h$schedule, now = function() h$state$clock
  )
  reconciler$baseline("thread", "session", "/synthetic")
  snapshot <- c(snapshot, list(list(id = "user", role = "user", content = "new question")))
  reconciler$reconcile(
    "thread", "session", "/synthetic", "run-error", must_advance = TRUE,
    watch_updates = TRUE, on_complete = callback
  )
  rm(callback)
  h$tick(0.1)
  h$tick(0.2)
  expect_identical(completed, 1L)
  expect_length(published, 1L)
  invisible(gc(full = TRUE))
  expect_true(collected)
  snapshot <- c(snapshot, list(list(id = "answer", role = "assistant", content = "late answer")))
  expect_true(h$tick(3))
  expect_true(h$tick(3.2))
  expect_length(published, 2L)
  expect_identical(completed, 1L)
  h$tick(31)
  expect_false(h$tick(32))
  expect_identical(completed, 1L)
  reconciler$invalidate()
})

test_that("a confirmed idle Result does not trigger another interrupt if reconciliation throws", {
  h <- long_task_harness(on_idle_result = function(message, on_complete) {
    stop("Synthetic history failure")
  })
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(long_task_message("ResultMessage", session_id = "confirmed"))
  h$tick(0)
  expect_identical(h$state$interrupts, 0L)
  expect_length(h$state$errors, 1L)
  expect_false(h$coordinator$is_busy())
})

test_that("an idle Assistant already present in the foreground baseline is still published", {
  f <- long_handler_fixture()
  f$state$transcript <- list(list(
    id = "h-early-background", role = "assistant",
    content = list(list(type = "text", text = "Already persisted background output"))
  ))
  f$state$queue <- list(
    f$result(),
    long_task_message(
      "AssistantMessage", uuid = "early-background", session_id = "synthetic-long",
      content = list(list(type = "text", text = "Already persisted background output"))
    )
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  expect_true(f$wait(function() length(f$state$histories) > 0L, timeout = 0.75))
  if (length(f$state$histories)) {
    expect_identical(f$state$histories[[1L]], f$state$transcript)
  }
})

test_that("idle preview requires the observed UUID rather than matching reply text", {
  h <- long_task_harness()
  snapshot <- list(list(id = "h-other", role = "assistant", content = "same text"))
  publications <- list()
  reconciler <- .new_claude_transcript_reconciler(
    read_snapshot = function(...) snapshot,
    publish = function(...) publications[[length(publications) + 1L]] <<- list(...),
    schedule = h$schedule, now = function() h$state$clock
  )
  reconciler$baseline("thread", "session", "/synthetic")
  reconciler$reconcile(
    "thread", "session", "/synthetic", "run", must_advance = TRUE,
    observed_message_id = "h-observed"
  )
  h$tick(0.1)
  h$tick(0.2)
  expect_length(publications, 0L)
  snapshot[[1L]]$id <- "h-observed"
  h$tick(0.3)
  h$tick(0.4)
  expect_length(publications, 1L)
  expect_null(.claude_history_message_id(long_task_message(
    "AssistantMessage", uuid = "thinking-only", content = list(list(type = "thinking", thinking = "internal"))
  )))
  reconciler$invalidate()
})

test_that("same-browser history refresh keeps its background approval and receives the real tool result", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "background-permission", agent_id = "background",
    tool_use_id = "task-call", tool_name = "Bash", tool_input = list(command = "echo synthetic")
  ))
  expect_true(f$wait(function() is.function(f$state$decision)))
  owner <- attr(f$handler, "ui_owner_snapshot")("long-handler")$owner
  expect_true(attr(f$handler, "attach_ui_owner")(
    "long-handler", owner, f$callbacks, history_only = TRUE
  ))
  expect_false(f$wait(function() f$state$approval_cancelled > 0L, timeout = 1.1))
  f$state$decision(list(approved = TRUE))
  expect_true(f$wait(function() length(f$state$approved) == 1L))
  f$state$queue <- list(long_task_message(
    "UserMessage", parent_tool_use_id = "task-call", content = list(long_task_message(
      "ToolResultBlock", tool_use_id = "task-call", content = "Real background tool result"
    ))
  ))
  expect_true(f$wait(function() any(vapply(f$state$tool_results, function(result) {
    any(unlist(result) == "Real background tool result")
  }, logical(1)))))
})

test_that("a different browser expires approval and drains before its next foreground turn", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "old-browser-permission", agent_id = "background",
    tool_use_id = "task-call", tool_name = "Bash", tool_input = list(command = "echo synthetic")
  ))
  expect_true(f$wait(function() is.function(f$state$decision)))
  expect_true(attr(f$handler, "attach_ui_owner")(
    "long-handler", "replacement-browser", f$callbacks, history_only = TRUE
  ))
  expect_true(f$wait(function() f$state$interrupts == 1L))
  expect_identical(f$state$denied, "old-browser-permission")
  expect_identical(f$state$approval_cancelled, 1L)
  f$state$queue <- list(long_task_message(
    "ResultMessage", session_id = "synthetic-long", is_error = TRUE, result = "Old interrupted turn"
  ))
  f$start("new-owner question", ui_owner = "replacement-browser", run_id = "run-replacement")
  expect_true(f$wait(function() length(f$state$sent) == 2L))
  expect_identical(f$state$done, 1L)
  expect_length(f$state$errors, 0L)
  f$state$queue <- list(f$result())
  expect_true(f$wait(function() f$state$done == 2L))
})

test_that("denying an associated background tool uses a single controlled interrupt", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "denied-permission", agent_id = "background",
    tool_use_id = "task-call", tool_name = "Bash", tool_input = list(command = "echo synthetic")
  ))
  expect_true(f$wait(function() is.function(f$state$decision)))
  f$state$decision(list(approved = FALSE))
  expect_true(f$wait(function() f$state$interrupts == 1L))
  expect_identical(f$state$denied, "denied-permission")
  f$state$queue <- list(long_task_message(
    "ResultMessage", session_id = "synthetic-long", is_error = TRUE, result = "Denied"
  ))
  expect_true(f$wait(function() !length(f$state$queue)))
  expect_identical(f$state$interrupts, 1L)
})

test_that("same-owner history paging cannot invalidate an active turn's callbacks", {
  f <- long_handler_fixture()
  f$start(ui_owner = "active-browser")
  expect_true(f$wait(function() length(f$state$sent) == 1L))
  original <- attr(f$handler, "ui_owner_snapshot")("long-handler")
  history_done <- 0L
  callbacks <- utils::modifyList(f$callbacks, list(
    on_done = function(...) history_done <<- history_done + 1L
  ))
  expect_true(attr(f$handler, "attach_ui_owner")(
    "long-handler", "active-browser", callbacks, history_only = TRUE
  ))
  current <- attr(f$handler, "ui_owner_snapshot")("long-handler")
  expect_identical(current$generation, original$generation)
  expect_false(f$wait(function() f$state$interrupts > 0L, timeout = 0.2))
  f$state$queue <- list(f$result())
  expect_true(f$wait(function() f$state$done == 1L))
  expect_identical(history_done, 0L)
  expect_length(f$state$errors, 0L)
})

test_that("a terminal during approval flushes deferred options after releasing the owner", {
  f <- long_handler_fixture()
  f$state$queue <- list(
    long_task_message("TaskStartedMessage", task_id = "background", tool_use_id = "task-call"),
    f$result()
  )
  f$start()
  expect_true(f$wait(function() f$state$done == 1L))
  f$state$queue <- list(long_task_message(
    "PermissionRequestMessage", request_id = "settings-permission", agent_id = "background",
    tool_use_id = "task-call", tool_name = "Bash", tool_input = list(command = "echo synthetic")
  ))
  expect_true(f$wait(function() is.function(f$state$decision)))
  attr(f$handler, "action_handler")("thinking:adaptive", "long-handler", function(...) NULL)
  expect_identical(f$state$disconnected, 0L)
  f$state$queue <- list(long_task_message(
    "TaskNotificationMessage", task_id = "background", status = "stopped"
  ))
  expect_true(f$wait(function() f$state$disconnected == 1L))
  expect_identical(attr(f$handler, "performance_snapshot")()$connected_clients, 0L)
  f$start("after settings", run_id = "run-new-settings")
  expect_true(f$wait(function() length(f$state$sent) == 2L))
  expect_identical(f$state$options$thinking$type, "adaptive")
  f$state$queue <- list(f$result())
  expect_true(f$wait(function() f$state$done == 2L))
})

test_that("idle release hooks cannot reset a connection with a buffered follow-up turn", {
  releases <- 0L
  h <- long_task_harness(on_idle_released = function() releases <<- releases + 1L)
  on.exit(h$coordinator$invalidate(), add = TRUE)
  h$coordinator$start_idle()
  h$push(
    long_task_message("ResultMessage", session_id = "first"),
    long_task_message("AssistantMessage", uuid = "already-running-follow-up")
  )
  h$tick(0)
  expect_identical(releases, 0L)
  h$tick(1)
  expect_identical(releases, 0L)
  expect_true(h$coordinator$is_busy())
  h$push(long_task_message("ResultMessage", session_id = "second"))
  h$tick(2)
  expect_identical(releases, 1L)
})

test_that("history handoff does not stamp new-owner background output with the old browser run id", {
  f <- long_handler_fixture()
  f$state$queue <- list(f$result())
  f$start(ui_owner = "old-browser")
  expect_true(f$wait(function() f$state$done == 1L))
  attr(f$handler, "detach_ui_owner")("old-browser")
  expect_true(attr(f$handler, "attach_ui_owner")(
    "long-handler", "new-browser", f$callbacks, history_only = TRUE
  ))
  f$state$transcript <- list(list(
    id = "h-new-browser-output", role = "assistant",
    content = list(list(type = "text", text = "New browser background output"))
  ))
  f$state$queue <- list(
    long_task_message("AssistantMessage", uuid = "new-browser-output", session_id = "synthetic-long",
                      content = list(list(type = "text", text = "New browser background output"))),
    f$result()
  )
  expect_true(f$wait(function() length(f$state$histories) > 0L))
  expect_length(f$state$history_run_ids, 1L)
  expect_null(f$state$history_run_ids[[1L]])
  f$state$queue <- list(
    long_task_message("AssistantMessage", content = list(
      list(type = "tool_use", id = "new-owner-call", name = "Bash")
    )),
    long_task_message("PermissionRequestMessage", request_id = "new-owner-permission",
                      tool_use_id = "new-owner-call", tool_name = "Bash", tool_input = list())
  )
  expect_true(f$wait(function() is.function(f$state$decision)))
  expect_length(f$state$denied, 0L)
})
