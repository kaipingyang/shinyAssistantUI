# Plan 14 B3：思考强度（thinking）为连接时 options → make_claude_handler(thinking_provider=)
# 让 make_opts 用动态 thinking，切换后配合 reset_clients 重连生效。

test_that("thinking_provider 覆盖 options$thinking 且随之变化", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })

  th <- list(type = "adaptive")
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    thinking_provider = function() th,
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  expect_identical(received$thinking, list(type = "adaptive"))

  th <- list(type = "enabled", budget_tokens = 8000L)
  attr(handler, "reset_clients")()
  attr(handler, "warmup")("t1")
  expect_identical(received$thinking$type, "enabled")
})

test_that("thinking action 切换强度、ui_capabilities 暴露、重连后生效", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  cap <- attr(handler, "ui_capabilities")$thinking
  expect_identical(cap$value, "default")
  expect_true("enabled" %in% vapply(cap$options, `[[`, character(1), "value"))

  attr(handler, "warmup")("t1")
  expect_null(received$thinking)                    # default → 不覆盖

  res <- NULL
  attr(handler, "action_handler")("thinking:enabled", "t1",
    function(message, status = "ok", value = NULL) res <<- list(status = status, value = value))
  expect_identical(res$status, "ok")
  expect_identical(res$value, "enabled")

  attr(handler, "warmup")("t1")                     # reset_clients 后重连
  expect_identical(received$thinking$type, "enabled")

  # 未知强度 → error
  res2 <- NULL
  attr(handler, "action_handler")("thinking:bogus", "t1",
    function(message, status = "ok", value = NULL) res2 <<- status)
  expect_identical(res2, "error")
})

test_that("thinking_provider=NULL 回退 options$thinking", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })
  handler <- make_claude_handler(
    options = list(thinking = list(type = "disabled"), permission_mode = "default",
                   permission_prompt_tool_name = "stdio", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  expect_identical(received$thinking$type, "disabled")
})
