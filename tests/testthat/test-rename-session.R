# Plan 14 B1：侧栏重命名同步到 SDK rename_session（server 模式重开标题不丢）。
# .claude_rename_session(thread_id, title, session_map_path, directory)：按 thread 反查 session_id → rename。

test_that(".claude_rename_session 对已映射线程调用 SDK rename_session（sid+title+dir）", {
  captured <- NULL
  testthat::local_mocked_bindings(
    .rename_claude_session = function(session_id, title, directory = NULL) {
      captured <<- list(sid = session_id, title = title, dir = directory); TRUE
    }
  )
  smap <- tempfile(fileext = ".rds"); saveRDS(list(t1 = "sid-1"), smap)
  ok <- shinyAssistantUI:::.claude_rename_session("t1", "New Title", smap, "/proj")
  expect_true(ok)
  expect_identical(captured$sid, "sid-1")
  expect_identical(captured$title, "New Title")
  expect_identical(captured$dir, "/proj")
})

test_that(".claude_rename_session 对无 session 的线程 no-op（不调用 SDK）", {
  called <- FALSE
  testthat::local_mocked_bindings(
    .rename_claude_session = function(session_id, title, directory = NULL) { called <<- TRUE; TRUE }
  )
  smap <- tempfile(fileext = ".rds"); saveRDS(list(), smap)
  ok <- shinyAssistantUI:::.claude_rename_session("t-unknown", "X", smap, "/proj")
  expect_false(isTRUE(ok))
  expect_false(called)
})
