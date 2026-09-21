test_that("make_claude_handler advertises all permission modes", {
  skip_if_not_installed("ClaudeAgentSDK")

  options <- ClaudeAgentSDK::ClaudeAgentOptions(permission_mode = "plan")
  handler <- make_claude_handler(
    options = options,
    session_map_path = tempfile(fileext = ".rds")
  )
  capability <- attr(handler, "ui_capabilities")$permission_mode

  expect_identical(capability$value, "plan")
  expect_identical(
    vapply(capability$options, `[[`, character(1), "value"),
    c("askAll", "default", "plan", "acceptEdits", "bypassPermissions", "yolo")
  )
  bypass <- Filter(function(x) identical(x$value, "bypassPermissions"), capability$options)[[1L]]
  expect_false(isTRUE(bypass$disabled))
})

test_that("YOLO (yolo) mode is advertised and dynamically selectable", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  cap <- attr(handler, "ui_capabilities")$permission_mode
  yolo <- Filter(function(x) identical(x$value, "yolo"), cap$options)
  expect_length(yolo, 1L)
  expect_identical(yolo[[1L]]$label, "YOLO")

  act <- attr(handler, "action_handler")
  captured <- new.env()
  act("permissions:yolo", "t1", send_action_result = function(message, status = "ok", value = NULL) {
    captured$status <- status; captured$value <- value
  })
  expect_identical(captured$status, "ok")
  expect_identical(captured$value, "yolo")
})

test_that("Strict (askAll) mode is advertised and dynamically selectable", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  cap <- attr(handler, "ui_capabilities")$permission_mode
  strict <- Filter(function(x) identical(x$value, "askAll"), cap$options)
  expect_length(strict, 1L)
  expect_identical(strict[[1L]]$label, "Strict")

  # action_handler 接受 permissions:askAll,不冷启动 client(cl NULL),回传 value=askAll。
  act <- attr(handler, "action_handler")
  captured <- new.env()
  act("permissions:askAll", "t1", send_action_result = function(message, status = "ok", value = NULL) {
    captured$status <- status; captured$value <- value
  })
  expect_identical(captured$status, "ok")
  expect_identical(captured$value, "askAll")
})

test_that("bypass mode is visible and dynamically selectable", {
  skip_if_not_installed("ClaudeAgentSDK")

  options <- ClaudeAgentSDK::ClaudeAgentOptions(permission_mode = "bypassPermissions")
  handler <- make_claude_handler(
    options = options,
    session_map_path = tempfile(fileext = ".rds")
  )
  capability <- attr(handler, "ui_capabilities")$permission_mode
  bypass <- Filter(function(x) identical(x$value, "bypassPermissions"),
                   capability$options)

  expect_identical(capability$value, "bypassPermissions")
  expect_length(bypass, 1L)
  expect_false(isTRUE(bypass[[1L]]$disabled))
})


test_that("permission actions accept advertised modes and do not cold-start a client", {
  skip_if_not_installed("ClaudeAgentSDK")

  handler <- make_claude_handler(
    options = ClaudeAgentSDK::ClaudeAgentOptions(permission_mode = "default"),
    session_map_path = tempfile(fileext = ".rds")
  )
  action <- attr(handler, "action_handler")
  results <- list()
  capture <- function(message, status = "ok", value = NULL) {
    results[[length(results) + 1L]] <<- list(
      message = message, status = status, value = value
    )
  }

  action("permissions:bogus", "thread-a", capture)
  action("permissions:bypassPermissions", "thread-a", capture)
  expect_identical(vapply(results, `[[`, character(1), "status"),
                   c("error", "ok"))
  expect_identical(results[[2L]]$value, "bypassPermissions")
  expect_match(results[[2L]]$message, "submitted")

  results <- list()
  action("permissions:plan", "thread-a", capture)
  expect_identical(results[[1L]]$status, "ok")
  expect_identical(results[[1L]]$value, "plan")
  expect_match(results[[1L]]$message, "submitted")

  # A permission selection before the first prompt records intended state only.
  # `context` therefore still sees no active SDK client.
  results <- list()
  action("context", "thread-a", capture)
  expect_identical(results[[1L]]$message, "No active session yet")
})


test_that("overriding the handler action dispatcher hides its UI capabilities", {
  handler <- function(...) NULL
  attr(handler, "action_handler") <- function(...) NULL
  attr(handler, "ui_capabilities") <- list(
    permission_mode = list(value = "default", options = list())
  )

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, on_action = function(id) NULL)
  }, {
    expect_null(widget_config(output$chat)$ui_capabilities)
  })
})


test_that("clear action requests a new UI thread after backend success", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(
    options = ClaudeAgentSDK::ClaudeAgentOptions(permission_mode = "default"),
    session_map_path = tempfile(fileext = ".rds")
  )
  result <- NULL
  attr(handler, "action_handler")(
    "clear", "thread-clear",
    function(message, status = "ok", value = NULL) {
      result <<- list(message = message, status = status, value = value)
    }
  )
  expect_identical(result$status, "ok")
  expect_identical(result$value, list(effect = "new-thread"))
})

test_that(".claude_suggestion_to_perm maps the three suggestion types", {
  skip_if_not_installed("ClaudeAgentSDK")
  r <- shinyAssistantUI:::.claude_suggestion_to_perm(list(
    type = "addRules",
    rules = list(list(toolName = "Bash", ruleContent = "rm:*")),
    behavior = "allow", destination = "session"))
  expect_identical(r$type, "addRules")

  d <- shinyAssistantUI:::.claude_suggestion_to_perm(list(
    type = "addDirectories", directories = list("/tmp/x"), destination = "session"))
  expect_identical(d$type, "addDirectories")

  m <- shinyAssistantUI:::.claude_suggestion_to_perm(list(
    type = "setMode", mode = "acceptEdits", destination = "session"))
  expect_identical(m$type, "setMode")
  expect_identical(m$mode, "acceptEdits")

  expect_null(shinyAssistantUI:::.claude_suggestion_to_perm(list(type = "unknownKind")))
  expect_null(shinyAssistantUI:::.claude_suggestion_to_perm(NULL))
})

test_that("approval cancellation unregisters only its own resolver and ignores a stale click", {
  wait <- NULL
  handler <- function(message, wait_for_approval, on_done) {
    wait <<- wait_for_approval
    on_done()
  }
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "synthetic", threadId = "approval-thread", runId = "approval-run", ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (is.function(wait)) break
    }
    decision <- NULL
    pending <- wait("same-tool")
    cancel <- attr(pending, "cancel", exact = TRUE)
    expect_true(is.function(cancel))
    if (is.function(cancel)) {
      promises::then(pending, function(value) decision <<- value)
      expect_true(cancel())
      expect_false(cancel())
      later::run_now(0)
      expect_true(decision$expired)

      replacement <- NULL
      promises::then(wait("same-tool"), function(value) replacement <<- value)
      expect_false(cancel())
      session$setInputs(chat_input_tool_approval = list(
        toolCallId = "same-tool", approved = TRUE, ts = 2
      ))
      session$flushReact()
      later::run_now(0)
      expect_true(replacement$approved)
    }
  })
})

test_that("owner-aware variadic handler wrappers receive the same identity as history attachment", {
  attached_owner <- received_owner <- NULL
  finished <- FALSE
  handler <- function(...) {
    args <- list(...)
    received_owner <<- args$ui_owner
    finished <<- TRUE
    args$on_done()
  }
  attr(handler, "attach_ui_owner") <- function(thread_id, ui_owner, callbacks, ...) {
    attached_owner <<- ui_owner
    TRUE
  }
  attr(handler, "detach_ui_owner") <- function(ui_owner) invisible(TRUE)
  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler,
      on_session_load = function(session_id, thread_id, send_thread) send_thread(list())
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "synthetic-session", threadId = "same-browser",
      requestId = "history-1", ts = 1
    ))
    session$flushReact()
    expect_true(is.character(attached_owner) && nzchar(attached_owner))
    session$setInputs(chat_input = list(
      text = "synthetic", threadId = "same-browser", runId = "run-1", ts = 2
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (finished) break
    }
    expect_true(finished)
    expect_identical(received_owner, attached_owner)
  })
})

test_that("ordinary variadic handlers do not receive a private browser identity", {
  received <- NULL
  handler <- function(...) {
    received <<- list(...)
    received$on_done()
  }
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "synthetic", threadId = "ordinary", runId = "ordinary-run", ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (!is.null(received)) break
    }
    expect_true(is.list(received))
    expect_false("ui_owner" %in% names(received))
  })
})

test_that("history-only attachment can await a later background approval without a new foreground run", {
  waiting <- NULL
  handler <- function(...) NULL
  attr(handler, "attach_ui_owner") <- function(thread_id, ui_owner, callbacks, ...) {
    waiting <<- callbacks$wait_for_approval
    TRUE
  }
  attr(handler, "detach_ui_owner") <- function(ui_owner) invisible(TRUE)
  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler,
      on_session_load = function(session_id, thread_id, send_thread) send_thread(list())
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "synthetic-session", threadId = "history-only",
      requestId = "history-only-request", ts = 1
    ))
    session$flushReact()
    expect_true(is.function(waiting))
    if (is.function(waiting)) {
      decision <- NULL
      promises::then(waiting("later-background-tool"), function(value) decision <<- value)
      session$setInputs(chat_input_tool_approval = list(
        toolCallId = "later-background-tool", approved = TRUE, ts = 2
      ))
      session$flushReact()
      later::run_now(0)
      expect_true(decision$approved)
    }
  })
})
