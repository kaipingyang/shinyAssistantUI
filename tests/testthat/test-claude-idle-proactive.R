plan91_scheduler <- function() {
  state <- new.env(parent = emptyenv())
  state$items <- list()

  schedule <- function(callback, delay) {
    item <- new.env(parent = emptyenv())
    item$callback <- callback
    item$delay <- delay
    item$cancelled <- FALSE
    state$items[[length(state$items) + 1L]] <- item
    function() {
      item$cancelled <- TRUE
      invisible(NULL)
    }
  }
  run_next <- function() {
    while (length(state$items) && isTRUE(state$items[[1L]]$cancelled)) {
      state$items <- state$items[-1L]
    }
    if (!length(state$items)) stop("Plan 91 scheduler is empty", call. = FALSE)
    item <- state$items[[1L]]
    state$items <- state$items[-1L]
    item$callback()
    invisible(item$delay)
  }
  run_all <- function(limit = 100L) {
    steps <- 0L
    repeat {
      state$items <- Filter(function(item) !isTRUE(item$cancelled), state$items)
      if (!length(state$items)) break
      steps <- steps + 1L
      if (steps > limit) stop("Plan 91 scheduler did not quiesce", call. = FALSE)
      run_next()
    }
    invisible(steps)
  }

  list(
    schedule = schedule,
    run_next = run_next,
    run_all = run_all,
    size = function() sum(vapply(state$items, function(item) !isTRUE(item$cancelled), logical(1)))
  )
}

plan91_sdk_message <- function(class, ...) {
  structure(list(...), class = class)
}

plan91_reason_text <- function(reason) {
  if (inherits(reason, "condition")) conditionMessage(reason) else as.character(reason)
}

plan91_drain_shiny <- function(session, done, limit = 200L) {
  for (i in seq_len(limit)) {
    later::run_now(0.01)
    session$flushReact()
    if (isTRUE(done())) return(invisible(TRUE))
  }
  invisible(FALSE)
}


test_that("idle empty polling backs off to 500ms and resets on a message", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  queue <- list(
    list(), list(), list(),
    list(plan91_sdk_message("TaskProgressMessage", task_id = "wake")),
    list()
  )
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      batch <- queue[[1L]] %||% list()
      queue <<- queue[-1L]
      batch
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle(0.1)
  delays <- vapply(seq_len(5L), function(index) scheduler$run_next(), numeric(1))
  expect_equal(delays, c(0.1, 0.2, 0.4, 0.5, 0.1))
  expect_identical(polls, 5L)
  expect_identical(
    coordinator$metrics()[c("idle_polls", "empty_idle_polls", "messages_seen", "idle_poll_ms")],
    list(idle_polls = 5L, empty_idle_polls = 4L, messages_seen = 1L, idle_poll_ms = 200)
  )
})


test_that("foreground ownership resets idle backoff without polling concurrently", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() { polls <<- polls + 1L; list() },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle(0.1)
  expect_equal(scheduler$run_next(), 0.1)
  expect_equal(scheduler$run_next(), 0.2)
  coordinator$acquire("foreground", function() invisible(NULL))
  coordinator$release("foreground")
  expect_equal(scheduler$run_next(), 0.1)
  expect_identical(polls, 3L)
})


test_that("consumer coordinator freezes the proposed internal surface", {
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() list(),
    schedule = function(callback, delay) invisible(NULL),
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) invisible(NULL),
    deny_idle_permission = function(message) invisible(NULL),
    interrupt = function() invisible(NULL)
  )

  expect_named(
    coordinator,
    c(
      "start_idle", "acquire", "poll_one", "release", "invalidate",
      "is_busy", "metrics"
    ),
    ignore.order = FALSE
  )
  expect_true(all(vapply(coordinator, is.function, logical(1))))
})


test_that("persistent idle events do not open a turn or block foreground", {
  scheduler <- plan91_scheduler()
  events <- list()
  acquired <- character()
  polls <- 0L
  queue <- list(list(plan91_sdk_message(
    "TaskProgressMessage", task_id = "task-1", status = "running"
  )))

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      batch <- queue[[1L]]
      queue <<- queue[-1L]
      batch
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) events[[length(events) + 1L]] <<- message,
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle()
  scheduler$run_next()

  expect_identical(polls, 1L)
  expect_length(events, 1L)
  expect_s3_class(events[[1L]], "TaskProgressMessage")
  expect_false(coordinator$is_busy())

  coordinator$acquire("foreground", function() acquired <<- "foreground")
  expect_identical(acquired, "foreground")
  expect_true(coordinator$is_busy())
  coordinator$release("foreground")
  expect_false(coordinator$is_busy())
})



test_that("replayed user events do not open an idle turn or block foreground", {
  scheduler <- plan91_scheduler()
  events <- list()
  acquired <- character()
  queue <- list(list(structure(
    list(content = "control replay", is_replay = TRUE),
    class = c("UserMessage", "list")
  )))

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      batch <- queue[[1L]]
      queue <<- queue[-1L]
      batch
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) events[[length(events) + 1L]] <<- message,
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle()
  scheduler$run_next()

  expect_length(events, 1L)
  expect_false(coordinator$is_busy())
  coordinator$acquire("foreground", function() acquired <<- "foreground")
  expect_identical(acquired, "foreground")
  coordinator$release("foreground")
})

test_that("foreground waits for an opened idle turn Result and reconciliation", {
  scheduler <- plan91_scheduler()
  acquired <- character()
  reconcile_done <- NULL
  results <- list()
  queue <- list(
    list(plan91_sdk_message("AssistantMessage", id = "cron-opener")),
    list(plan91_sdk_message("ResultMessage", session_id = "session-1"))
  )

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      batch <- queue[[1L]]
      queue <<- queue[-1L]
      batch
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) {
      results[[length(results) + 1L]] <<- message
      reconcile_done <<- on_complete
    },
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle()
  scheduler$run_next()
  expect_true(coordinator$is_busy())

  coordinator$acquire("foreground", function() acquired <<- "foreground")
  expect_length(acquired, 0L)

  scheduler$run_next()
  expect_length(results, 1L)
  expect_s3_class(results[[1L]], "ResultMessage")
  expect_true(is.function(reconcile_done))
  expect_length(acquired, 0L)
  expect_true(coordinator$is_busy())

  reconcile_done()
  expect_identical(acquired, "foreground")
  expect_true(coordinator$is_busy())
  coordinator$release("foreground")
  expect_false(coordinator$is_busy())
})


test_that("raw batch tail after Result is retained for the next owner", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  acquired <- character()
  reconcile_done <- NULL
  batch <- list(
    plan91_sdk_message("AssistantMessage", id = "cron-a"),
    plan91_sdk_message("ResultMessage", session_id = "session-a"),
    plan91_sdk_message("AssistantMessage", id = "cron-b")
  )

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      if (polls == 1L) batch else list()
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) reconcile_done <<- on_complete,
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle()
  scheduler$run_next()
  coordinator$acquire("foreground", function() acquired <<- "foreground")
  while (is.null(reconcile_done) && scheduler$size()) scheduler$run_next()

  expect_true(is.function(reconcile_done))
  expect_length(acquired, 0L)
  reconcile_done()
  expect_identical(acquired, "foreground")

  tail <- coordinator$poll_one("foreground")
  expect_s3_class(tail, "AssistantMessage")
  expect_identical(tail$id, "cron-b")
  expect_identical(polls, 1L)
  coordinator$release("foreground")
})


test_that("only the current owner can poll and acquire waiters are FIFO", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  acquired <- character()

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      list(plan91_sdk_message("AssistantMessage", id = "one"))
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$acquire("owner-a", function() acquired <<- c(acquired, "owner-a"))
  coordinator$acquire("owner-b", function() acquired <<- c(acquired, "owner-b"))
  coordinator$acquire("owner-c", function() acquired <<- c(acquired, "owner-c"))

  expect_identical(acquired, "owner-a")
  expect_error(coordinator$poll_one("owner-b"), "owner", ignore.case = TRUE)
  expect_identical(polls, 0L)
  expect_s3_class(coordinator$poll_one("owner-a"), "AssistantMessage")
  expect_identical(polls, 1L)

  coordinator$release("owner-a")
  expect_identical(acquired, c("owner-a", "owner-b"))
  coordinator$release("owner-b")
  expect_identical(acquired, c("owner-a", "owner-b", "owner-c"))
  coordinator$release("owner-c")
  expect_false(coordinator$is_busy())
})


test_that("idle permission deny failure interrupts and never approves interactively", {
  scheduler <- plan91_scheduler()
  deny_calls <- 0L
  interrupts <- 0L
  approvals <- 0L
  failures <- character()
  request <- plan91_sdk_message(
    "PermissionRequestMessage",
    request_id = "permission-1",
    approve = function(...) approvals <<- approvals + 1L
  )

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() list(request, request),
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) {
      failures <<- c(failures, plan91_reason_text(reason))
    },
    deny_idle_permission = function(message) {
      deny_calls <<- deny_calls + 1L
      stop("deny transport failed")
    },
    interrupt = function() interrupts <<- interrupts + 1L
  )

  coordinator$start_idle()
  scheduler$run_next()

  expect_identical(deny_calls, 1L)
  expect_identical(interrupts, 1L)
  expect_identical(approvals, 0L)
  expect_length(failures, 1L)
  expect_match(failures[[1L]], "deny transport failed", fixed = TRUE)
  expect_false(coordinator$is_busy())
})


test_that("idle timeout fails closed and releases a foreground waiter", {
  scheduler <- plan91_scheduler()
  clock <- 0
  interrupts <- 0L
  failures <- character()
  acquired <- character()
  polls <- 0L

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      if (polls == 1L) {
        list(plan91_sdk_message("AssistantMessage", id = "never-finishes"))
      } else {
        list()
      }
    },
    schedule = scheduler$schedule,
    now = function() clock,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) {
      failures <<- c(failures, plan91_reason_text(reason))
    },
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() interrupts <<- interrupts + 1L
  )

  coordinator$start_idle()
  scheduler$run_next()
  coordinator$acquire("foreground", function() acquired <<- "foreground")
  expect_length(acquired, 0L)

  clock <- 1e9
  scheduler$run_next()

  expect_identical(interrupts, 1L)
  expect_length(failures, 1L)
  expect_match(failures[[1L]], "timed out", ignore.case = TRUE)
  expect_identical(acquired, "foreground")
  coordinator$release("foreground")
  expect_false(coordinator$is_busy())
})


test_that("invalidating a generation makes already scheduled idle work stale", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  events <- 0L

  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      polls <<- polls + 1L
      list(plan91_sdk_message("AssistantMessage", id = "stale"))
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) events <<- events + 1L,
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) invisible(NULL),
    deny_idle_permission = function(message) invisible(NULL),
    interrupt = function() invisible(NULL)
  )

  coordinator$start_idle()
  expect_gt(scheduler$size(), 0L)
  coordinator$invalidate()
  scheduler$run_all()

  expect_identical(polls, 0L)
  expect_identical(events, 0L)
  expect_false(coordinator$is_busy())
})


test_that("transcript reconciler freezes the proposed internal surface", {
  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) list(),
    publish = function(thread_id, messages, revision, after_run_id) invisible(NULL),
    schedule = function(callback, delay) invisible(NULL),
    now = function() 0,
    quiet_delay = 0.1,
    deadline = 2
  )

  expect_named(
    reconciler,
    c("baseline", "reconcile", "invalidate", "has_published"),
    ignore.order = FALSE
  )
  expect_true(all(vapply(reconciler, is.function, logical(1))))
})


test_that("must_advance waits through S0 S0 S1 S1 before publishing", {
  scheduler <- plan91_scheduler()
  s0 <- list(list(
    id = "h-1", role = "assistant",
    content = list(list(type = "text", text = "old"))
  ))
  s1 <- list(list(
    id = "h-1", role = "assistant",
    content = list(list(type = "text", text = "new cron output"))
  ))
  reads <- list(s0, s0, s0, s1, s1)
  published <- list()
  completed <- list()

  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) {
      value <- reads[[1L]]
      reads <<- reads[-1L]
      value
    },
    publish = function(thread_id, messages, revision, after_run_id) {
      published[[length(published) + 1L]] <<- list(
        thread_id = thread_id,
        messages = messages,
        revision = revision,
        after_run_id = after_run_id
      )
    },
    schedule = scheduler$schedule,
    now = function() 0,
    quiet_delay = 0,
    deadline = 10
  )

  reconciler$baseline("thread-1", "session-1", "/project/a")
  reconciler$reconcile(
    thread_id = "thread-1",
    session_id = "session-1",
    project = "/project/a",
    after_run_id = "run-7",
    must_advance = TRUE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) {
      completed[[length(completed) + 1L]] <<- list(ok = ok, reason = reason)
    }
  )
  scheduler$run_all()

  expect_length(published, 1L)
  expect_identical(published[[1L]]$messages, s1)
  expect_identical(published[[1L]]$revision, 1L)
  expect_identical(published[[1L]]$after_run_id, "run-7")
  expect_length(completed, 1L)
  expect_true(completed[[1L]]$ok)
  expect_true(reconciler$has_published())
})


test_that("same message ID content mutation publishes a new full snapshot", {
  scheduler <- plan91_scheduler()
  before <- list(list(
    id = "h-tool", role = "assistant",
    content = list(list(type = "tool-call", toolCallId = "tool-1", result = NULL))
  ))
  after <- list(list(
    id = "h-tool", role = "assistant",
    content = list(list(
      type = "tool-call", toolCallId = "tool-1", result = "completed"
    ))
  ))
  reads <- list(before, after, after)
  published <- list()

  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) {
      value <- reads[[1L]]
      reads <<- reads[-1L]
      value
    },
    publish = function(thread_id, messages, revision, after_run_id) {
      published[[length(published) + 1L]] <<- list(
        thread_id = thread_id, messages = messages, revision = revision,
        after_run_id = after_run_id
      )
    },
    schedule = scheduler$schedule,
    now = function() 0,
    quiet_delay = 0,
    deadline = 10
  )

  reconciler$baseline("thread-tool", "shared-session", "/project/a")
  reconciler$reconcile(
    "thread-tool", "shared-session", "/project/a", "run-tool", FALSE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) expect_true(ok)
  )
  scheduler$run_all()

  expect_length(published, 1L)
  expect_identical(published[[1L]]$messages, after)
  expect_identical(vapply(published[[1L]]$messages, `[[`, "", "id"), "h-tool")
})


test_that("same session ID is reconciled independently for each project", {
  scheduler <- plan91_scheduler()
  a0 <- list(list(id = "h-a", role = "assistant", content = "A0"))
  a1 <- list(list(id = "h-a", role = "assistant", content = "A1"))
  b0 <- list(list(id = "h-b", role = "assistant", content = "B0"))
  queues <- list(
    "/project/a" = list(a0, a1, a1),
    "/project/b" = list(b0, b0, b0)
  )
  published <- list()

  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) {
      value <- queues[[project]][[1L]]
      queues[[project]] <<- queues[[project]][-1L]
      value
    },
    publish = function(thread_id, messages, revision, after_run_id) {
      published[[length(published) + 1L]] <<- list(
        thread_id = thread_id, messages = messages, revision = revision,
        after_run_id = after_run_id
      )
    },
    schedule = scheduler$schedule,
    now = function() 0,
    quiet_delay = 0,
    deadline = 10
  )

  reconciler$baseline("thread-a", "same-session", "/project/a")
  reconciler$baseline("thread-b", "same-session", "/project/b")
  reconciler$reconcile(
    "thread-a", "same-session", "/project/a", "run-a", FALSE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) expect_true(ok)
  )
  scheduler$run_all()
  reconciler$reconcile(
    "thread-b", "same-session", "/project/b", "run-b", FALSE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) expect_true(ok)
  )
  scheduler$run_all()

  expect_length(published, 1L)
  expect_identical(published[[1L]]$thread_id, "thread-a")
  expect_identical(published[[1L]]$messages, a1)
})


test_that("stale reconciliation generation cannot publish", {
  scheduler <- plan91_scheduler()
  s0 <- list(list(id = "h-1", role = "assistant", content = "old"))
  s1 <- list(list(id = "h-1", role = "assistant", content = "new"))
  reads <- list(s0, s1, s1)
  published <- list()
  completed <- list()
  current <- TRUE

  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) {
      value <- reads[[1L]]
      reads <<- reads[-1L]
      value
    },
    publish = function(...) published[[length(published) + 1L]] <<- list(...),
    schedule = scheduler$schedule,
    now = function() 0,
    quiet_delay = 0,
    deadline = 10
  )

  reconciler$baseline("thread-1", "session-1", "/project/a")
  reconciler$reconcile(
    "thread-1", "session-1", "/project/a", "run-stale", TRUE,
    is_current = function() current,
    on_complete = function(ok, reason = NULL) {
      completed[[length(completed) + 1L]] <<- list(ok = ok, reason = reason)
    }
  )
  current <- FALSE
  reconciler$invalidate()
  scheduler$run_all()

  expect_length(published, 0L)
  expect_false(reconciler$has_published())
  if (length(completed)) expect_false(completed[[1L]]$ok)
})


test_that("must_advance timeout retains last good state and reports failure", {
  scheduler <- plan91_scheduler()
  clock <- 0
  s0 <- list(list(id = "h-1", role = "assistant", content = "old"))
  s1 <- list(list(id = "h-1", role = "assistant", content = "new"))
  candidate <- s0
  published <- list()
  completed <- list()

  reconciler <- shinyAssistantUI:::.new_claude_transcript_reconciler(
    read_snapshot = function(thread_id, session_id, project) candidate,
    publish = function(thread_id, messages, revision, after_run_id) {
      published[[length(published) + 1L]] <<- list(
        thread_id = thread_id, messages = messages, revision = revision,
        after_run_id = after_run_id
      )
    },
    schedule = scheduler$schedule,
    now = function() clock,
    quiet_delay = 0,
    deadline = 2
  )

  reconciler$baseline("thread-1", "session-1", "/project/a")
  reconciler$reconcile(
    "thread-1", "session-1", "/project/a", "run-timeout", TRUE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) {
      completed[[length(completed) + 1L]] <<- list(ok = ok, reason = reason)
    }
  )
  expect_gt(scheduler$size(), 0L)
  clock <- 3
  scheduler$run_all()

  expect_length(published, 0L)
  expect_length(completed, 1L)
  expect_false(completed[[1L]]$ok)
  expect_match(plan91_reason_text(completed[[1L]]$reason), "timed out", ignore.case = TRUE)
  expect_false(reconciler$has_published())

  candidate <- s1
  reconciler$reconcile(
    "thread-1", "session-1", "/project/a", "run-retry", TRUE,
    is_current = function() TRUE,
    on_complete = function(ok, reason = NULL) {
      completed[[length(completed) + 1L]] <<- list(ok = ok, reason = reason)
    }
  )
  scheduler$run_all()

  expect_length(published, 1L)
  expect_identical(published[[1L]]$messages, s1)
  expect_identical(published[[1L]]$revision, 1L)
  expect_identical(published[[1L]]$after_run_id, "run-retry")
})


test_that("assistantUIServer provides persistent proactive callbacks without run state", {
  sent <- list()
  callbacks <- new.env(parent = emptyenv())
  transcript <- list(list(
    id = "h-proactive", role = "assistant",
    content = list(list(type = "text", text = "scheduled report"))
  ))

  handler <- function(message, on_proactive_messages, on_proactive_task,
                      on_proactive_status, on_done) {
    callbacks$messages <- on_proactive_messages
    callbacks$task <- on_proactive_task
    callbacks$status <- on_proactive_status
    on_proactive_task(
      task_id = "cron-task", kind = "progress", status = "running",
      summary = "Checking background work"
    )
    on_proactive_status(status = "cron", text = "Scheduled turn active")
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "start", threadId = "thread-proactive", runId = "run-1",
      attachments = list(), ts = 1
    ))
    expect_true(plan91_drain_shiny(
      session,
      function() any(vapply(
        sent,
        function(item) item$type %in% c("chat_input:done", "chat_input:error"),
        logical(1)
      ))
    ))

    callbacks_ready <- c(
      messages = is.function(callbacks$messages),
      task = is.function(callbacks$task),
      status = is.function(callbacks$status)
    )
    expect_true(callbacks_ready[["messages"]])
    expect_true(callbacks_ready[["task"]])
    expect_true(callbacks_ready[["status"]])
    if (all(callbacks_ready)) {
      callbacks$messages(
      messages = transcript,
      revision = 4L,
      after_run_id = "run-1"
    )
    session$flushReact()

    proactive <- Filter(
      function(item) identical(item$type, "chat_input:proactive-messages"), sent
    )
    expect_length(proactive, 1L)
    expect_identical(
      proactive[[1L]]$message,
      list(
        version = 1L,
        operation = "replace",
        threadId = "thread-proactive",
        revision = 4L,
        afterRunId = "run-1",
        messages = transcript
      )
    )

    task <- Filter(function(item) identical(item$type, "chat_input:task"), sent)
    status <- Filter(function(item) identical(item$type, "chat_input:status"), sent)
    expect_length(task, 1L)
    expect_length(status, 1L)
    expect_identical(task[[1L]]$message$threadId, "thread-proactive")
    expect_null(task[[1L]]$message$runId)
    expect_identical(status[[1L]]$message$threadId, "thread-proactive")

    run_phases <- vapply(
      Filter(function(item) identical(item$type, "chat_input:run-state"), sent),
      function(item) item$message$phase,
      character(1)
    )
      expect_false("running" %in% run_phases)
    }
  })
})


test_that("assistantUIServer keeps handlers with old formals compatible", {
  received <- character()
  sent <- list()
  handler <- function(message, on_chunk, on_done) {
    received <<- c(received, message)
    on_chunk("legacy handler reply")
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "legacy request", threadId = "legacy-thread", runId = "legacy-run",
      attachments = list(), ts = 1
    ))
    expect_true(plan91_drain_shiny(session, function() any(vapply(
      sent, function(item) identical(item$type, "chat_input:done"), logical(1)
    ))))

    expect_identical(received, "legacy request")
    chunks <- Filter(function(item) identical(item$type, "chat_input:chunk"), sent)
    expect_length(chunks, 1L)
    expect_identical(chunks[[1L]]$message$text, "legacy handler reply")
  })
})


test_that("idle start delay leaves an unopened consumer immediately preemptible", {
  scheduler <- plan91_scheduler()
  polls <- 0L
  acquired <- character()
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() { polls <<- polls + 1L; list() },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle(1)
  coordinator$acquire("foreground", function() acquired <<- "foreground")

  expect_identical(acquired, "foreground")
  expect_identical(polls, 0L)
  coordinator$release("foreground")
  expect_identical(scheduler$run_next(), 0.1)
})


test_that("idle permission denial is deduplicated by generation and request id", {
  scheduler <- plan91_scheduler()
  deny_calls <- 0L
  interrupts <- 0L
  queue <- list(
    list(plan91_sdk_message("PermissionRequestMessage", request_id = "same-request")),
    list(plan91_sdk_message("PermissionRequestMessage", request_id = "same-request"))
  )
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      if (!length(queue)) return(list())
      value <- queue[[1L]]
      queue <<- queue[-1L]
      value
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason) invisible(NULL),
    deny_idle_permission = function(message) deny_calls <<- deny_calls + 1L,
    interrupt = function() interrupts <<- interrupts + 1L
  )

  coordinator$start_idle()
  scheduler$run_next()
  coordinator$start_idle()
  scheduler$run_next()

  expect_identical(deny_calls, 1L)
  expect_identical(interrupts, 2L)
  coordinator$invalidate()
})


test_that("compact polling can consume one coordinator-owned message at a time", {
  scheduled <- list()
  terminal <- list()
  polls <- 0L
  messages <- list(
    plan91_sdk_message("SystemMessage", data = list(status = "compacting")),
    plan91_sdk_message("ResultMessage", session_id = "compact-owned", is_error = FALSE)
  )

  shinyAssistantUI:::.claude_start_compact_poll(
    client = NULL,
    poll_one = function() {
      polls <<- polls + 1L
      if (!length(messages)) return(NULL)
      value <- messages[[1L]]
      messages <<- messages[-1L]
      value
    },
    on_terminal = function(status, message) {
      terminal[[length(terminal) + 1L]] <<- list(status = status, message = message)
    },
    timeout_seconds = 10,
    poll_interval = 0,
    schedule = function(callback, delay) scheduled[[length(scheduled) + 1L]] <<- callback
  )
  while (length(scheduled)) {
    callback <- scheduled[[1L]]
    scheduled <- scheduled[-1L]
    callback()
  }

  expect_identical(polls, 2L)
  expect_length(terminal, 1L)
  expect_identical(terminal[[1L]]$status, "ok")
})


test_that("make_claude_handler performs authoritative idle and post-foreground convergence", {
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  old_delay <- getOption("shinyAssistantUI.claude_idle_start_delay")
  options(shinyAssistantUI.claude_idle_start_delay = 0)
  on.exit(options(shinyAssistantUI.claude_idle_start_delay = old_delay), add = TRUE)

  queue <- list()
  sent <- character()
  disconnected <- 0L
  transcript <- list(list(id = "m0", role = "assistant", content = "initial"))
  directories <- character()
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() { disconnected <<- disconnected + 1L; invisible(NULL) }
  client$send <- function(content) sent <<- c(sent, as.character(content))
  client$interrupt <- function(...) invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    if (!length(queue)) return(list())
    value <- queue[[1L]]
    queue <<- queue[-1L]
    value
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .get_claude_session_messages = function(session_id, directory = NULL, ...) {
      directories <<- c(directories, directory %||% "")
      transcript
    },
    .claude_msgs_to_thread = function(messages, ...) messages,
    .claude_drain_timeout_seconds = function() 0.01
  )
  map_path <- tempfile(fileext = ".rds")
  saveRDS(list(`thread-integration` = "session-integration"), map_path)
  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = map_path
  )

  proactive <- list()
  run_turn <- function(run_id, project, result_text) {
    done <- FALSE
    error <- NULL
    queue <<- c(queue, list(list(plan91_sdk_message(
      "ResultMessage", session_id = "session-integration", is_error = FALSE,
      result = result_text, usage = list()
    ))))
    handler(
      message = paste("request", run_id), thread_id = "thread-integration",
      run_id = run_id, project = project, attachments = list(),
      on_chunk = function(...) invisible(NULL),
      on_done = function(...) done <<- TRUE,
      on_error = function(message) error <<- message,
      on_tool_call = function(...) invisible(NULL),
      on_tool_result = function(...) invisible(NULL),
      on_thinking = function(...) invisible(NULL),
      on_proactive_messages = function(messages, revision, after_run_id = NULL) {
        proactive[[length(proactive) + 1L]] <<- list(
          messages = messages, revision = revision, after_run_id = after_run_id
        )
      },
      on_proactive_task = function(...) invisible(NULL),
      on_proactive_rate_limit = function(...) invisible(NULL),
      on_proactive_status = function(...) invisible(NULL),
      is_cancelled = function() FALSE,
      wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
    )
    for (i in seq_len(500L)) {
      later::run_now(0.01)
      if (done || !is.null(error)) break
    }
    expect_null(error)
    expect_true(done)
  }

  run_turn("run-1", "/project/owner", "first")
  transcript <- list(list(id = "m0", role = "assistant", content = "proactive mutation"))
  queue <- list(list(
    plan91_sdk_message("AssistantMessage", session_id = "session-integration"),
    plan91_sdk_message("ResultMessage", session_id = "session-integration", is_error = FALSE)
  ))
  for (i in seq_len(500L)) {
    later::run_now(0.01)
    if (length(proactive) >= 1L) break
  }
  expect_length(proactive, 1L)
  expect_identical(proactive[[1L]]$after_run_id, "run-1")

  transcript <- list(list(id = "m0", role = "assistant", content = "foreground mutation"))
  run_turn("run-2", "/project/not-owner", "second")
  expect_length(proactive, 2L)
  expect_identical(proactive[[2L]]$after_run_id, "run-2")
  expect_true(all(directories == "/project/owner"))
  expect_identical(sent, c("request run-1", "request run-2"))

  attr(handler, "cleanup")()
  expect_identical(disconnected, 1L)
  before <- length(proactive)
  queue <- list(list(
    plan91_sdk_message("AssistantMessage", session_id = "session-integration"),
    plan91_sdk_message("ResultMessage", session_id = "session-integration", is_error = FALSE)
  ))
  for (i in seq_len(20L)) later::run_now(0.01)
  expect_identical(length(proactive), before)
})


test_that("idle Result reconciles even when no opener preceded it", {
  scheduler <- plan91_scheduler()
  reconciled <- 0L
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = local({
      queue <- list(list(plan91_sdk_message(
        "ResultMessage", session_id = "result-only"
      )))
      function() {
        if (!length(queue)) return(list())
        value <- queue[[1L]]
        queue <<- queue[-1L]
        value
      }
    }),
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) stop("Result is not an idle event"),
    on_idle_result = function(message, on_complete) {
      reconciled <<- reconciled + 1L
      on_complete()
    },
    on_idle_failure = function(reason) stop(plan91_reason_text(reason)),
    deny_idle_permission = function(message) stop("unexpected permission request"),
    interrupt = function() stop("unexpected interrupt")
  )

  coordinator$start_idle()
  scheduler$run_next()

  expect_identical(reconciled, 1L)
  expect_false(coordinator$is_busy())
  coordinator$invalidate()
})


test_that("assistantUIServer forwards the browser run id to compatible handlers", {
  received_run_id <- NULL
  sent <- list()
  handler <- function(message, run_id, on_done) {
    received_run_id <<- run_id
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "run id contract", threadId = "thread-run-id",
      runId = "run-contract-91", attachments = list(), ts = 1
    ))
    expect_true(plan91_drain_shiny(session, function() any(vapply(
      sent, function(item) identical(item$type, "chat_input:done"), logical(1)
    ))))
    expect_identical(received_run_id, "run-contract-91")
  })
})


test_that("idle Assistant content publishes before Result and transient status stays hidden", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  old_delay <- getOption("shinyAssistantUI.claude_idle_start_delay")
  options(shinyAssistantUI.claude_idle_start_delay = 0)
  on.exit(options(shinyAssistantUI.claude_idle_start_delay = old_delay), add = TRUE)

  queue <- list(ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "idle-preview-session",
    result = "foreground complete", stop_reason = "end_turn"
  ))
  transcript <- list(list(
    id = "foreground", role = "assistant",
    content = list(list(type = "text", text = "foreground complete"))
  ))
  client <- new.env(parent = emptyenv())
  client$connect <- client$disconnect <- client$send <- function(...) invisible(NULL)
  client$deny_tool <- client$approve_tool <- client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .get_claude_session_messages = function(session_id, directory = NULL, ...) transcript,
    .claude_msgs_to_thread = function(messages, ...) messages,
    .package = "shinyAssistantUI"
  )

  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  cleanup <- attr(handler, "cleanup")
  if (is.function(cleanup)) on.exit(cleanup(), add = TRUE)

  foreground_done <- FALSE
  proactive <- list()
  statuses <- list()
  handler(
    message = "start background deploy", thread_id = "idle-preview-thread",
    attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) foreground_done <<- TRUE,
    on_error = function(message) stop(message),
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE)),
    on_proactive_messages = function(messages, revision, after_run_id) {
      proactive[[length(proactive) + 1L]] <<- list(
        messages = messages, revision = revision, after_run_id = after_run_id
      )
    },
    on_proactive_status = function(status, text = NULL) {
      statuses[[length(statuses) + 1L]] <<- list(status = status, text = text)
    },
    run_id = "foreground-run"
  )
  expect_true(plan91_drain_shiny(
    session = list(flushReact = function() invisible(NULL)),
    done = function() foreground_done,
    limit = 400L
  ))

  transcript <- c(transcript, list(list(
    id = "proactive-mid", role = "assistant",
    content = list(list(type = "text", text = "background finished; checking log"))
  )))
  queue <- list(
    plan91_sdk_message(
      "SystemMessage", subtype = "status", data = list(status = "requesting")
    ),
    plan91_sdk_message(
      "SystemMessage", subtype = "status", data = list(status = "background-ready")
    ),
    plan91_sdk_message(
      "AssistantMessage", session_id = "idle-preview-session",
      content = list()
    )
  )

  for (i in seq_len(400L)) {
    later::run_now(0.01)
    if (length(proactive)) break
  }

  expect_length(proactive, 1L)
  expect_identical(
    proactive[[1L]]$messages[[2L]]$content[[1L]]$text,
    "background finished; checking log"
  )
  expect_false(any(vapply(
    statuses,
    function(value) identical(value$text, "requesting") ||
      identical(value$status, "requesting"),
    logical(1)
  )))
  expect_true(any(vapply(
    statuses,
    function(value) identical(value$text, "background-ready"),
    logical(1)
  )))
})


test_that("foreground-created task ownership excludes detached idle tasks", {
  tracker <- shinyAssistantUI:::.new_claude_background_task_ownership()
  associated <- plan91_sdk_message(
    "TaskStartedMessage", task_id = "agent-owned", tool_use_id = "tool-agent"
  )
  detached <- plan91_sdk_message(
    "TaskStartedMessage", task_id = "agent-idle", tool_use_id = "tool-idle"
  )
  tracker$observe(associated, foreground = TRUE)
  tracker$observe(detached, foreground = FALSE)

  expect_true(tracker$owns(plan91_sdk_message(
    "PermissionRequestMessage", request_id = "p-owned",
    agent_id = "agent-owned", tool_use_id = "tool-agent"
  )))
  expect_false(tracker$owns(plan91_sdk_message(
    "PermissionRequestMessage", request_id = "p-idle",
    agent_id = "agent-idle", tool_use_id = "tool-idle"
  )))

  tracker$observe(plan91_sdk_message(
    "TaskNotificationMessage", task_id = "agent-owned", status = "completed"
  ), foreground = FALSE)
  expect_false(tracker$owns(plan91_sdk_message(
    "PermissionRequestMessage", request_id = "p-after-terminal",
    agent_id = "agent-owned", tool_use_id = "tool-agent"
  )))
})


test_that("associated idle permission waits for approval and terminal reconciliation", {
  scheduler <- plan91_scheduler()
  permission_done <- NULL
  foreground <- character()
  denied <- 0L
  results <- 0L
  queue <- list(
    list(plan91_sdk_message(
      "PermissionRequestMessage", request_id = "associated", agent_id = "agent-owned"
    )),
    list(plan91_sdk_message("ResultMessage", session_id = "session-owned"))
  )
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() {
      value <- queue[[1L]] %||% list()
      queue <<- queue[-1L]
      value
    },
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) {
      results <<- results + 1L
      on_complete()
    },
    on_idle_failure = function(reason, on_complete) on_complete(),
    handle_idle_permission = function(message, on_complete, on_failure) {
      permission_done <<- on_complete
      TRUE
    },
    deny_idle_permission = function(message) denied <<- denied + 1L,
    interrupt = function() invisible(NULL)
  )

  coordinator$start_idle()
  scheduler$run_next()
  coordinator$acquire("foreground:next", function() foreground <<- "acquired")
  expect_true(is.function(permission_done))
  expect_length(foreground, 0L)
  expect_identical(denied, 0L)

  permission_done()
  scheduler$run_next()
  expect_identical(results, 1L)
  expect_identical(foreground, "acquired")
  coordinator$release("foreground:next")
})


test_that("detached idle denial holds owner until failure reconciliation completes", {
  scheduler <- plan91_scheduler()
  failure_done <- NULL
  foreground <- character()
  failures <- character()
  denied <- 0L
  interrupted <- 0L
  coordinator <- shinyAssistantUI:::.new_claude_consumer_coordinator(
    poll_messages = function() list(plan91_sdk_message(
      "PermissionRequestMessage", request_id = "detached"
    )),
    schedule = scheduler$schedule,
    now = function() 0,
    on_idle_event = function(message) invisible(NULL),
    on_idle_result = function(message, on_complete) on_complete(),
    on_idle_failure = function(reason, on_complete) {
      failures <<- c(failures, plan91_reason_text(reason))
      failure_done <<- on_complete
    },
    deny_idle_permission = function(message) denied <<- denied + 1L,
    interrupt = function() interrupted <<- interrupted + 1L
  )

  coordinator$start_idle()
  scheduler$run_next()
  coordinator$acquire("foreground:queued", function() foreground <<- "acquired")

  expect_identical(denied, 1L)
  expect_identical(interrupted, 1L)
  expect_length(failures, 1L)
  expect_identical(
    failures[[1L]],
    "A background task requested approval and was stopped because no interactive run was available."
  )
  expect_true(is.function(failure_done))
  expect_length(foreground, 0L)
  expect_true(coordinator$is_busy())

  failure_done()
  expect_identical(foreground, "acquired")
  coordinator$release("foreground:queued")
})


test_that("make_claude_handler routes owned background approval and reconciles detached denial", {
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  old_delay <- getOption("shinyAssistantUI.claude_idle_start_delay")
  options(shinyAssistantUI.claude_idle_start_delay = 0)
  on.exit(options(shinyAssistantUI.claude_idle_start_delay = old_delay), add = TRUE)

  queue <- list()
  transcript <- list(list(id = "baseline", role = "assistant", content = "before"))
  approvals <- character()
  denials <- character()
  interrupts <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$get_server_info <- function() list(commands = list(), output_styles = list())
  client$approve_tool <- function(request_id, ...) approvals <<- c(approvals, request_id)
  client$deny_tool <- function(request_id, ...) denials <<- c(denials, request_id)
  client$interrupt <- function(...) interrupts <<- interrupts + 1L
  client$poll_messages <- function() {
    if (!length(queue)) return(list())
    value <- queue[[1L]]
    queue <<- queue[-1L]
    value
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .get_claude_session_messages = function(session_id, directory = NULL, ...) transcript,
    .claude_msgs_to_thread = function(messages, ...) messages,
    .claude_drain_timeout_seconds = function() 0.01
  )
  map_path <- tempfile(fileext = ".rds")
  saveRDS(list(`thread-owned` = "session-owned"), map_path)
  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = map_path
  )
  on.exit(attr(handler, "cleanup")(), add = TRUE)

  cards <- list()
  proactive <- list()
  statuses <- character()
  events <- character()
  approval_resolve <- NULL
  done <- FALSE
  error <- NULL
  queue <- list(list(
    plan91_sdk_message(
      "TaskStartedMessage", task_id = "agent-owned", tool_use_id = "task-tool",
      description = "Owned child task", task_type = "Agent"
    ),
    plan91_sdk_message(
      "ResultMessage", session_id = "session-owned", is_error = FALSE,
      result = "foreground complete", usage = list()
    )
  ))
  handler(
    message = "start owned task", thread_id = "thread-owned", run_id = "run-owned",
    attachments = list(),
    on_chunk = function(...) invisible(NULL),
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_tool_call = function(...) cards[[length(cards) + 1L]] <<- list(...),
    on_tool_result = function(...) invisible(NULL),
    on_thinking = function(...) invisible(NULL),
    on_task = function(...) invisible(NULL),
    on_proactive_messages = function(messages, revision, after_run_id = NULL) {
      events <<- c(events, "transcript")
      proactive[[length(proactive) + 1L]] <<- messages
    },
    on_proactive_task = function(...) invisible(NULL),
    on_proactive_rate_limit = function(...) invisible(NULL),
    on_proactive_status = function(status, text = NULL, ...) {
      events <<- c(events, "status")
      statuses <<- c(statuses, text %||% status)
    },
    is_cancelled = function() FALSE,
    wait_for_approval = function(tool_call_id) promises::promise(function(resolve, reject) {
      approval_resolve <<- resolve
    })
  )
  for (i in seq_len(300L)) {
    later::run_now(0.01)
    if (done || !is.null(error)) break
  }
  expect_null(error)
  expect_true(done)

  queue <- list(
    list(plan91_sdk_message(
      "PermissionRequestMessage", request_id = "approve-owned",
      tool_use_id = "task-tool", agent_id = "agent-owned",
      tool_name = "Bash", tool_input = list(command = "echo safe")
    )),
    list(plan91_sdk_message(
      "ResultMessage", session_id = "session-owned", is_error = FALSE
    ))
  )
  for (i in seq_len(300L)) {
    later::run_now(0.01)
    if (length(cards) && is.function(approval_resolve)) break
  }
  expect_length(cards, 1L)
  expect_identical(cards[[1L]]$tool_call_id, "task-tool")
  expect_true(is.function(approval_resolve))
  expect_length(denials, 0L)

  proactive_before_approval <- length(proactive)
  approval_resolve(list(approved = TRUE))
  for (i in seq_len(300L)) {
    later::run_now(0.01)
    if (identical(approvals, "approve-owned") && !length(queue)) break
  }
  expect_identical(approvals, "approve-owned")
  expect_length(queue, 0L)
  expect_length(proactive, proactive_before_approval)

  transcript <- list(list(
    id = "associated-delayed", role = "assistant",
    content = "Reply persisted after associated approval Result"
  ))
  for (i in seq_len(500L)) {
    later::run_now(0.01)
    if (length(proactive) > proactive_before_approval) break
  }
  expect_gt(length(proactive), proactive_before_approval)
  expect_true(any(grepl("Reply persisted after associated approval", vapply(
    proactive, function(messages) as.character(messages[[1L]]$content), character(1)
  ), fixed = TRUE)))

  transcript <- list(list(
    id = "detached-reply", role = "assistant",
    content = "Reply written before detached approval interruption"
  ))
  events <- character()
  queue <- list(list(plan91_sdk_message(
    "PermissionRequestMessage", request_id = "deny-detached",
    tool_name = "Bash", tool_input = list(command = "detached")
  )))
  for (i in seq_len(500L)) {
    later::run_now(0.01)
    if (length(statuses) && length(proactive) >= 1L &&
        identical(tail(denials, 1L), "deny-detached")) break
  }

  expect_identical(tail(denials, 1L), "deny-detached")
  expect_gte(interrupts, 1L)
  expect_true(any(grepl("Reply written before detached approval", vapply(
    proactive, function(messages) as.character(messages[[1L]]$content), character(1)
  ), fixed = TRUE)))
  expect_true(any(statuses == paste0(
    "A background task requested approval and was stopped because ",
    "no interactive run was available."
  )))
  expect_identical(events[seq_len(min(2L, length(events)))], c("transcript", "status"))
})
