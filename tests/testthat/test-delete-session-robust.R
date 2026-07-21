# Plan 17：删除会话健壮性 —— 断开 client、失败不静默、真删验证。

# Step 1：release_session 断开并丢弃仍连着该 session 的 client。
test_that("release_session 断开并移除该 session 对应线程的 client", {
  skip_if_not_installed("ClaudeAgentSDK")
  disconnected <- FALSE
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() { disconnected <<- TRUE; invisible(NULL) }

  smap <- tempfile(fileext = ".rds")
  saveRDS(list(t1 = "sid-1"), smap)   # thread t1 → session sid-1

  testthat::local_mocked_bindings(.new_claude_client = function(options) client)
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = smap
  )
  attr(handler, "warmup")("t1")                 # 连接并缓存 clients[["t1"]]=client
  tids <- attr(handler, "release_session")("sid-1")
  expect_true("t1" %in% tids)
  expect_true(disconnected)                     # 断开被调用
  # 再 warmup 会重连（client 已被丢弃）→ 不报错即可
  expect_silent(attr(handler, "warmup")("t1"))
})

# Step 2：删除成功清 map；失败则不清 map、触发 on_reappear（诚实反馈，不静默假装成功）。
test_that(".claude_delete_session：成功清映射、失败触发重现且不清映射", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- structure(function(...) NULL,
                       release_session = function(session_id) character(0))
  archived <- tempfile(fileext = ".rds")
  smap <- tempfile(fileext = ".rds"); saveRDS(list(t1 = "sid-x"), smap)

  # 成功
  reappear <- FALSE
  testthat::local_mocked_bindings(.delete_claude_session = function(session_id, directory = NULL) TRUE)
  ok <- shinyAssistantUI:::.claude_delete_session(
    "sid-x", project = tempdir(), handler = handler,
    archived_path = archived, session_map_path = smap,
    on_reappear = function() reappear <<- TRUE)
  expect_true(ok)
  expect_false(reappear)
  expect_null(shinyAssistantUI:::.read_claude_session_map(smap)[["t1"]])  # 映射已清

  # 失败
  saveRDS(list(t2 = "sid-y"), smap)
  reappear2 <- FALSE
  testthat::local_mocked_bindings(
    .delete_claude_session = function(session_id, directory = NULL) stop("Session not found"))
  ok2 <- suppressWarnings(shinyAssistantUI:::.claude_delete_session(
    "sid-y", project = tempdir(), handler = handler,
    archived_path = archived, session_map_path = smap,
    on_reappear = function() reappear2 <<- TRUE))
  expect_false(ok2)
  expect_true(reappear2)                                   # 失败 → 重现回调触发
  expect_identical(shinyAssistantUI:::.read_claude_session_map(smap)[["t2"]], "sid-y")  # 未清
})

# Step 3：真删端到端（隔离在临时 CLAUDE_CONFIG_DIR，不碰用户 ~/.claude）。
test_that("真删：delete_session 移除磁盘 .jsonl，重删报错", {
  skip_if_not_installed("ClaudeAgentSDK")
  tmp_cfg <- tempfile("claude-cfg-"); dir.create(tmp_cfg)
  old <- Sys.getenv("CLAUDE_CONFIG_DIR", unset = NA)
  Sys.setenv(CLAUDE_CONFIG_DIR = tmp_cfg)
  on.exit(if (is.na(old)) Sys.unsetenv("CLAUDE_CONFIG_DIR") else Sys.setenv(CLAUDE_CONFIG_DIR = old), add = TRUE)

  project <- normalizePath(tempfile("proj-"), mustWork = FALSE); dir.create(project)
  proj_dir <- ClaudeAgentSDK:::.get_project_dir(project)
  dir.create(proj_dir, recursive = TRUE, showWarnings = FALSE)
  uuid <- "11111111-1111-1111-1111-111111111111"
  jsonl <- file.path(proj_dir, paste0(uuid, ".jsonl"))
  writeLines('{"type":"user","message":{"role":"user","content":"hi"}}', jsonl)
  expect_true(file.exists(jsonl))

  expect_true(shinyAssistantUI:::.delete_claude_session(uuid, directory = project))
  expect_false(file.exists(jsonl))                          # 文件真被删
  expect_error(shinyAssistantUI:::.delete_claude_session(uuid, directory = project))  # 重删找不到 → 报错
})
