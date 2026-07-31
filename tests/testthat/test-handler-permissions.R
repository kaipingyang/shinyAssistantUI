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
