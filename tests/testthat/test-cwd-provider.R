# Plan 18 Phase 3a：make_claude_handler 支持动态 cwd_provider + reset_clients（切工作目录用）。

test_that("cwd_provider 覆盖 options$cwd 且随之变化（切目录后重连用新 cwd）", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })

  dir <- "/tmp/dir-A"
  handler <- make_claude_handler(
    options = list(cwd = "/tmp/static", permission_mode = "default",
                   permission_prompt_tool_name = "stdio", include_partial_messages = TRUE),
    cwd_provider = function() dir,
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  expect_identical(received$cwd, "/tmp/dir-A")     # provider 覆盖了静态 options$cwd

  dir <- "/tmp/dir-B"
  attr(handler, "reset_clients")()                 # 换目录 → 断开所有 client
  attr(handler, "warmup")("t1")                    # 重连
  expect_identical(received$cwd, "/tmp/dir-B")     # 用新目录
})

test_that("reset_clients 断开并清空所有 client", {
  skip_if_not_installed("ClaudeAgentSDK")
  disconnected <- 0L
  make_client <- function() {
    cl <- new.env(parent = emptyenv())
    cl$connect <- function() invisible(NULL)
    cl$disconnect <- function() { disconnected <<- disconnected + 1L; invisible(NULL) }
    cl
  }
  testthat::local_mocked_bindings(.new_claude_client = function(options) make_client())
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  attr(handler, "warmup")("t2")
  attr(handler, "reset_clients")()
  # Plan 57:断开改异步(不阻塞 addin UI)→ 注册表同步清空,子进程 disconnect 挪到 later
  expect_identical(disconnected, 0L)               # 调用未同步阻塞在断开上
  if (requireNamespace("later", quietly = TRUE)) later::run_now()
  expect_identical(disconnected, 2L)               # flush 后两个 client 都断开
  expect_silent(attr(handler, "warmup")("t1"))     # 清空后可重连
})

test_that("cwd_provider=NULL 时回退 options$cwd（非 addin 兼容）", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) { received <<- options; client })
  handler <- make_claude_handler(
    options = list(cwd = "/tmp/static", permission_mode = "default",
                   permission_prompt_tool_name = "stdio", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  expect_identical(received$cwd, "/tmp/static")
})


test_that("reset_clients waits for every concurrent normal turn and runs once", {
  skip_if_not_installed("ClaudeAgentSDK")
  cancelled <- list(a = FALSE, b = FALSE)
  finished <- list(a = FALSE, b = FALSE)
  disconnects <- 0L
  clients <- lapply(c("a", "b"), function(id) {
    client <- new.env(parent = emptyenv())
    client$connect <- function() invisible(NULL)
    client$disconnect <- function() {
      disconnects <<- disconnects + 1L
      invisible(NULL)
    }
    client$send <- function(...) invisible(NULL)
    client$interrupt <- function(...) invisible(NULL)
    client$poll_messages <- function() list()
    client$get_server_info <- function() list()
    client
  })
  next_client <- 0L
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) {
      next_client <<- next_client + 1L
      clients[[next_client]]
    },
    .claude_drain_timeout_seconds = function() 0
  )
  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("a")
  attr(handler, "warmup")("b")
  invoke <- function(id) handler(
    message = id, thread_id = id, attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) finished[[id]] <<- TRUE,
    on_error = function(...) finished[[id]] <<- TRUE,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() isTRUE(cancelled[[id]]),
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  invoke("a")
  invoke("b")
  later::run_now()

  attr(handler, "reset_clients")()
  later::run_now()
  expect_identical(disconnects, 0L)

  cancelled$a <- TRUE
  for (i in seq_len(100L)) {
    later::run_now()
    if (isTRUE(finished$a)) break
    Sys.sleep(0.002)
  }
  expect_true(finished$a)
  expect_false(finished$b)
  expect_identical(disconnects, 0L)

  cancelled$b <- TRUE
  for (i in seq_len(100L)) {
    later::run_now()
    if (isTRUE(finished$b) && disconnects == 2L) break
    Sys.sleep(0.002)
  }
  expect_true(finished$b)
  expect_identical(disconnects, 2L)
  later::run_now()
  expect_identical(disconnects, 2L)
})


test_that("reset_clients waits for compact terminal before disconnecting", {
  skip_if_not_installed("ClaudeAgentSDK")
  disconnects <- 0L
  compact_terminal <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() {
    disconnects <<- disconnects + 1L
    invisible(NULL)
  }
  client$send <- function(...) invisible(NULL)
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_start_compact_poll = function(client, on_progress, on_terminal,
                                           persist_result, ...) {
      compact_terminal <<- on_terminal
      invisible(NULL)
    }
  )
  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("compact-thread")
  attr(handler, "action_handler")(
    "compact", "compact-thread", function(...) invisible(NULL)
  )
  expect_true(is.function(compact_terminal))

  attr(handler, "reset_clients")()
  later::run_now()
  expect_identical(disconnects, 0L)

  compact_terminal("ok", "Compacted")
  later::run_now()
  expect_identical(disconnects, 1L)
})
