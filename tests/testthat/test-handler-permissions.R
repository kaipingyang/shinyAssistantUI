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
    c("default", "plan", "acceptEdits", "bypassPermissions")
  )
  bypass <- capability$options[[4L]]
  expect_false(isTRUE(bypass$disabled))
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
    widget_json <- jsonlite::fromJSON(output$chat, simplifyVector = FALSE)
    expect_null(widget_json$x$config$ui_capabilities)
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
