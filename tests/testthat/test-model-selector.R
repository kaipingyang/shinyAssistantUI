# Plan 14 #1：/model 接线。set_model 是热切换（不重连）；默认档位 default/haiku/sonnet/opus，
# models= 可覆盖（default 恒在首位）。重连（如切工作目录）后 make_opts 仍带当前模型，不回退。

test_that("model capability 暴露默认档位 + model:<alias> 热切换 + 重连保持", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL; set_calls <- character()
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  client$set_model <- function(m) set_calls[[length(set_calls) + 1L]] <<- m
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })

  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  cap <- attr(handler, "ui_capabilities")$model
  expect_identical(cap$value, "default")
  expect_true(all(c("default", "haiku", "sonnet", "opus") %in%
                    vapply(cap$options, `[[`, character(1), "value")))

  attr(handler, "warmup")("t1")
  expect_null(received$model)   # default → 不覆盖

  res <- NULL
  attr(handler, "action_handler")("model:sonnet", "t1",
    function(message, status = "ok", value = NULL) res <<- list(status = status, value = value))
  expect_identical(res$status, "ok")
  expect_identical(res$value, "sonnet")
  expect_true("sonnet" %in% set_calls)          # 立即 set_model（热切换）

  attr(handler, "reset_clients")()
  attr(handler, "warmup")("t1")
  expect_identical(received$model, "sonnet")     # 重连后仍带 sonnet

  # 未知模型 → error
  res2 <- NULL
  attr(handler, "action_handler")("model:bogus", "t1",
    function(message, status = "ok", value = NULL) res2 <<- status)
  expect_identical(res2, "error")
})

test_that("models= 覆盖档位、default 恒在首位、按传入顺序", {
  skip_if_not_installed("ClaudeAgentSDK")
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) client)
  handler <- make_claude_handler(
    models = c("gpt-4o", "claude-x"),
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  vals <- vapply(attr(handler, "ui_capabilities")$model$options, `[[`, character(1), "value")
  expect_identical(vals, c("default", "gpt-4o", "claude-x"))
})
