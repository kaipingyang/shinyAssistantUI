# run_r MCP 开关(Plan 45):.filter_run_r_mcp 关掉时摘除 r_session。

test_that(".filter_run_r_mcp removes r_session only when disabled", {
  ff <- shinyAssistantUI:::.filter_run_r_mcp
  ms <- list(r_session = list(type = "stdio"), other = list(type = "stdio"))
  # enabled → 原样保留
  keep <- ff(ms, TRUE)
  expect_true("r_session" %in% names(keep))
  expect_true("other" %in% names(keep))
  # disabled → 仅摘 r_session,其它保留
  drop <- ff(ms, FALSE)
  expect_false("r_session" %in% names(drop))
  expect_true("other" %in% names(drop))
  # 无 r_session / NULL / 非 list 时安全
  expect_identical(ff(list(other = 1), FALSE), list(other = 1))
  expect_null(ff(NULL, FALSE))
})

test_that(".addin_run_r_allowed_tools 仅在 autorun 开时加 run_r", {
  at <- shinyAssistantUI:::.addin_run_r_allowed_tools
  expect_null(at(FALSE, NULL))
  expect_identical(at(TRUE, NULL), "mcp__r_session__run_r")
  expect_identical(at(TRUE, c("mcp__r_session__run_r")), c("mcp__r_session__run_r"))  # 不重复
})
