# Plan 14 A5：编辑追踪器除"揭示最近一次"外，还收集本轮所有成功编辑（喂 Markers 面板）。

test_that("edit tracker take_edits 收集本轮成功编辑（跳过失败）、flush 独立揭示最近一次", {
  t <- shinyAssistantUI:::.new_edit_reveal_tracker()
  t$note_call("c1", "Edit", list(file_path = "R/a.R"))
  t$note_result("c1", is_error = FALSE)
  t$note_call("c2", "Write", list(file_path = "R/b.R"))
  t$note_result("c2", is_error = FALSE)
  t$note_call("c3", "Edit", list(file_path = "R/c.R"))
  t$note_result("c3", is_error = TRUE)     # 失败 → 不计
  t$note_call("c4", "Read", list(file_path = "R/d.R"))  # 非编辑工具 → 不计
  t$note_result("c4", is_error = FALSE)

  edits <- t$take_edits()
  paths <- vapply(edits, function(e) e$path, character(1))
  expect_identical(paths, c("R/a.R", "R/b.R"))   # 仅成功的编辑工具

  expect_identical(t$take_edits(), list())        # 取走后清空

  # flush（揭示最近一次成功编辑）仍独立可用
  expect_identical(t$flush(), "R/b.R")
})

test_that(".addin_edit_markers 去重、相对路径转绝对、带 type/line/message", {
  edits <- list(list(path = "R/a.R"), list(path = "R/b.R"), list(path = "R/a.R"),
                list(path = "/abs/x.R"))
  m <- shinyAssistantUI:::.addin_edit_markers(edits, project = "/proj")
  # 去重后 3 条，顺序保持
  expect_length(m, 3L)
  expect_identical(vapply(m, `[[`, character(1), "file"),
                   c("/proj/R/a.R", "/proj/R/b.R", "/abs/x.R"))   # 相对→绝对、绝对保持
  expect_true(all(vapply(m, `[[`, character(1), "type") == "info"))
  expect_true(all(vapply(m, `[[`, numeric(1), "line") == 1))
  expect_true(nzchar(m[[1]]$message))
})

test_that(".addin_edit_markers 空输入 → 空", {
  expect_length(shinyAssistantUI:::.addin_edit_markers(list(), "/proj"), 0L)
})
