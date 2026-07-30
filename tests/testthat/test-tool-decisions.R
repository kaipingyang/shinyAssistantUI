# 历史 session 审批/拒绝状态持久化(Bug: 重开历史 session 看不到 Approved/Denied)。

test_that(".record_tool_decision / .read_tool_decisions round-trip", {
  path <- tempfile(fileext = ".rds")
  on.exit(unlink(path), add = TRUE)
  expect_identical(shinyAssistantUI:::.read_tool_decisions(path), list())  # 不存在→空
  shinyAssistantUI:::.record_tool_decision(path, "tu_1", "approved")
  shinyAssistantUI:::.record_tool_decision(path, "tu_2", "denied")
  d <- shinyAssistantUI:::.read_tool_decisions(path)
  expect_identical(d[["tu_1"]], "approved")
  expect_identical(d[["tu_2"]], "denied")
  # 覆盖更新
  shinyAssistantUI:::.record_tool_decision(path, "tu_1", "denied")
  expect_identical(shinyAssistantUI:::.read_tool_decisions(path)[["tu_1"]], "denied")
  # NULL path / 空 id 安全
  expect_null(shinyAssistantUI:::.record_tool_decision(NULL, "x", "approved"))
  expect_identical(shinyAssistantUI:::.read_tool_decisions(NULL), list())
})

test_that(".prune_tool_decisions removes given ids, keeps others (Plan 46 delete cleanup)", {
  path <- tempfile(fileext = ".rds"); on.exit(unlink(path), add = TRUE)
  shinyAssistantUI:::.record_tool_decision(path, "tu_a", "approved")
  shinyAssistantUI:::.record_tool_decision(path, "tu_b", "denied")
  shinyAssistantUI:::.record_tool_decision(path, "tu_c", "approved")
  shinyAssistantUI:::.prune_tool_decisions(path, c("tu_a", "tu_c"))
  d <- shinyAssistantUI:::.read_tool_decisions(path)
  expect_null(d[["tu_a"]]); expect_null(d[["tu_c"]])
  expect_identical(d[["tu_b"]], "denied")
  # 空 / NULL 安全
  expect_null(shinyAssistantUI:::.prune_tool_decisions(path, character(0)))
  expect_null(shinyAssistantUI:::.prune_tool_decisions(NULL, "x"))
})

test_that(".claude_decisions_path 由 session_map_path 派生 sibling", {
  p <- shinyAssistantUI:::.claude_decisions_path("/home/u/.claude_addin/session_map.rds")
  expect_identical(basename(p), "tool_decisions.rds")
  expect_identical(dirname(p), "/home/u/.claude_addin")
  expect_null(shinyAssistantUI:::.claude_decisions_path(NULL))
  expect_null(shinyAssistantUI:::.claude_decisions_path(""))
})

test_that(".claude_msgs_to_thread 把历史决策回填到 tool-call part 的 artifact", {
  msgs <- list(
    list(type = "assistant", uuid = "a1", message = list(content = list(
      list(type = "tool_use", id = "tu_1", name = "Bash", input = list(command = "ls"))
    ))),
    list(type = "user", uuid = "u1", message = list(content = list(
      list(type = "tool_result", tool_use_id = "tu_1", content = "done", is_error = FALSE)
    )))
  )
  # 无决策:artifact 有 isError,无 approvalResult
  th0 <- shinyAssistantUI:::.claude_msgs_to_thread(msgs)
  part0 <- Filter(function(p) identical(p$type, "tool-call"), th0[[1]]$content)[[1]]
  expect_false(isTRUE(part0$artifact$isError))
  expect_null(part0$artifact$approvalResult)
  # 有决策:approvalResult 回填
  th1 <- shinyAssistantUI:::.claude_msgs_to_thread(msgs, list(tu_1 = "denied"))
  part1 <- Filter(function(p) identical(p$type, "tool-call"), th1[[1]]$content)[[1]]
  expect_identical(part1$artifact$approvalResult, "denied")
  expect_identical(part1$toolCallId, "tu_1")
})
