# 方案B：Archive 持久化软隐藏 + Delete 真删的 R 侧单元测试

test_that(".read/.write_archived_ids 按 project 隔离并原子往返", {
  path <- tempfile(fileext = ".rds")
  proj_a <- tempfile("projA")
  proj_b <- tempfile("projB")
  dir.create(proj_a); dir.create(proj_b)

  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj_a), character(0))

  shinyAssistantUI:::.write_archived_ids(path, proj_a, c("s1", "s2"))
  shinyAssistantUI:::.write_archived_ids(path, proj_b, c("s9"))

  expect_setequal(shinyAssistantUI:::.read_archived_ids(path, proj_a), c("s1", "s2"))
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj_b), "s9")
  # A 的修改不影响 B
  shinyAssistantUI:::.write_archived_ids(path, proj_a, character(0))
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj_a), character(0))
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj_b), "s9")
})

test_that(".toggle_archived_id 增删幂等", {
  path <- tempfile(fileext = ".rds")
  proj <- tempfile("proj"); dir.create(proj)

  shinyAssistantUI:::.toggle_archived_id(path, proj, "s1", TRUE)
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj), "s1")
  # 重复归档幂等
  shinyAssistantUI:::.toggle_archived_id(path, proj, "s1", TRUE)
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj), "s1")
  # 取消归档
  shinyAssistantUI:::.toggle_archived_id(path, proj, "s1", FALSE)
  expect_identical(shinyAssistantUI:::.read_archived_ids(path, proj), character(0))
})

test_that(".annotate_archived 给 session 标记 archived 布尔", {
  sessions <- list(
    list(id = "s1", title = "A"),
    list(id = "s2", title = "B"),
    list(id = "s3", title = "C")
  )
  out <- shinyAssistantUI:::.annotate_archived(sessions, c("s2"))
  expect_false(isTRUE(out[[1]]$archived))
  expect_true(isTRUE(out[[2]]$archived))
  expect_false(isTRUE(out[[3]]$archived))
  # 空归档列表 → 全部 active
  out2 <- shinyAssistantUI:::.annotate_archived(sessions, character(0))
  expect_false(any(vapply(out2, function(s) isTRUE(s$archived), logical(1))))
})
