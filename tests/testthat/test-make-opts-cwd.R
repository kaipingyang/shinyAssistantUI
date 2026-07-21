# Phase 1（Plan 16）：make_opts 必须把 options 的 cwd / system_prompt 透传给 ClaudeAgentOptions，
# 否则 Claude CLI 子进程只会继承 R 进程 getwd()，插件无法指定工作目录。
# 测法：mock .new_claude_client 捕获它实际收到的（真实构造的）ClaudeAgentOptions，断言其 $cwd/$system_prompt。

test_that("make_opts 透传 cwd 与 system_prompt 给真实 ClaudeAgentOptions", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)

  testthat::local_mocked_bindings(
    .new_claude_client = function(options) { received <<- options; client }
  )
  handler <- make_claude_handler(
    options = list(
      cwd                         = "/tmp/my-workdir",
      system_prompt               = "MY-SYSTEM-PROMPT",
      permission_mode             = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages    = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")   # → get_client → make_opts → .new_claude_client(<opts>)

  expect_s3_class(received, "ClaudeAgentOptions")
  expect_identical(received$cwd, "/tmp/my-workdir")
  expect_identical(received$system_prompt, "MY-SYSTEM-PROMPT")
})

test_that("options 无 cwd 时 cwd 为 NULL（回退继承 getwd，不报错）", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(
    .new_claude_client = function(options) { received <<- options; client }
  )
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t2")
  expect_null(received$cwd)
})
