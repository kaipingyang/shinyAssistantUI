# Plan 14 A2：编辑前保存活动文档，但跳过 untitled（无路径）脚本。
# 纯逻辑 .addin_savable_doc_id(ctx)：有路径+id → 返回 id；untitled/无 ctx → NULL。

test_that(".addin_savable_doc_id：有路径返回 id", {
  ctx <- list(id = "doc-1", path = "/proj/R/app.R")
  expect_identical(shinyAssistantUI:::.addin_savable_doc_id(ctx), "doc-1")
})

test_that(".addin_savable_doc_id：untitled（无路径）→ NULL（不保存）", {
  expect_null(shinyAssistantUI:::.addin_savable_doc_id(list(id = "doc-2", path = "")))
  expect_null(shinyAssistantUI:::.addin_savable_doc_id(list(id = "doc-3")))       # 无 path 字段
  expect_null(shinyAssistantUI:::.addin_savable_doc_id(NULL))                      # 无 ctx
  expect_null(shinyAssistantUI:::.addin_savable_doc_id(list(path = "/x/a.R")))     # 无 id
})
