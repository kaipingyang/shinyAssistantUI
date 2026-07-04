# 本会话改动的 R 纯函数 helper 单元测试
# 内部函数（. 前缀未导出），用 ::: 访问

# ── .attachment_text_sections（file 附件提示注入）──────────────────────────────

test_that(".attachment_text_sections 空列表返回空字符串", {
  f <- shinyAssistantUI:::.attachment_text_sections
  expect_equal(f(list()), "")
})

test_that(".attachment_text_sections 纯 text 附件合并", {
  f <- shinyAssistantUI:::.attachment_text_sections
  atts <- list(
    list(type = "text", data = "hello"),
    list(type = "text", data = "world")
  )
  expect_equal(f(atts), "hello\nworld")
})

test_that(".attachment_text_sections file 附件格式化为提示", {
  f <- shinyAssistantUI:::.attachment_text_sections
  atts <- list(list(type = "file", name = "report.pdf", contentType = "application/pdf"))
  expect_equal(
    f(atts),
    "[Attached file: report.pdf (application/pdf) — binary content not directly readable]"
  )
})

test_that(".attachment_text_sections file 缺 name/contentType 用默认", {
  f <- shinyAssistantUI:::.attachment_text_sections
  atts <- list(list(type = "file"))
  expect_equal(
    f(atts),
    "[Attached file: unnamed (unknown type) — binary content not directly readable]"
  )
})

test_that(".attachment_text_sections 混合：text 在前 file 在后", {
  f <- shinyAssistantUI:::.attachment_text_sections
  atts <- list(
    list(type = "file", name = "a.csv", contentType = "text/csv"),
    list(type = "text", data = "note"),
    list(type = "image", data = "data:image/png;base64,xxx")  # image 不参与
  )
  out <- f(atts)
  expect_equal(
    out,
    "note\n[Attached file: a.csv (text/csv) — binary content not directly readable]"
  )
})

test_that(".attachment_text_sections text data 为 NULL 退化为空串", {
  f <- shinyAssistantUI:::.attachment_text_sections
  atts <- list(list(type = "text", data = NULL))
  expect_equal(f(atts), "")
})

# ── .claude_msgs_to_thread（session 历史转 ThreadMessageLike）───────────────────

test_that(".claude_msgs_to_thread 用户字符串 content", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "user", uuid = "u1", message = list(content = "hi there")))
  out <- f(msgs)
  expect_length(out, 1)
  expect_equal(out[[1]]$role, "user")
  expect_equal(out[[1]]$id, "h-u1")
  expect_equal(out[[1]]$content[[1]]$text, "hi there")
})

test_that(".claude_msgs_to_thread 用户列表 content 提取 text 块", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "user", uuid = "u2", message = list(content = list(
    list(type = "text", text = "part1"),
    list(type = "text", text = "part2")
  ))))
  out <- f(msgs)
  expect_length(out, 1)
  expect_equal(out[[1]]$content[[1]]$text, "part1part2")
})

test_that(".claude_msgs_to_thread 空白用户消息被过滤", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "user", uuid = "u3", message = list(content = "   ")))
  expect_length(f(msgs), 0)
})

test_that(".claude_msgs_to_thread assistant text + tool_use 块", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "assistant", uuid = "a1", message = list(content = list(
    list(type = "text", text = "let me check"),
    list(type = "tool_use", id = "t1", name = "get_weather", input = list(city = "Beijing"))
  ))))
  out <- f(msgs)
  expect_length(out, 1)
  expect_equal(out[[1]]$role, "assistant")
  expect_length(out[[1]]$content, 2)
  expect_equal(out[[1]]$content[[1]]$type, "text")
  expect_equal(out[[1]]$content[[2]]$type, "tool-call")
  expect_equal(out[[1]]$content[[2]]$toolCallId, "t1")
  expect_equal(out[[1]]$content[[2]]$toolName, "get_weather")
  expect_equal(out[[1]]$content[[2]]$result, "Session ended")
})

test_that(".claude_msgs_to_thread assistant tool_use 缺 id/name 用默认", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "assistant", uuid = "a2", message = list(content = list(
    list(type = "tool_use", input = list())
  ))))
  out <- f(msgs)
  expect_equal(out[[1]]$content[[1]]$toolName, "unknown")
  expect_match(out[[1]]$content[[1]]$toolCallId, "^h-tool-")
})

test_that(".claude_msgs_to_thread 无 part 的 assistant 消息被过滤", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(list(type = "assistant", uuid = "a3", message = list(content = list())))
  expect_length(f(msgs), 0)
})

test_that(".claude_msgs_to_thread 空输入返回空列表", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  expect_equal(f(list()), list())
})
