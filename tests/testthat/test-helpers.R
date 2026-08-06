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

test_that(".claude_msgs_to_thread 不因缺 type 字段的消息崩溃(NULL==... 修复)", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  # JSONL 里可能有不带 `type` 的行;旧代码 `m$type == "user"/"assistant"` 会得
  # logical(0) → if 抛 "argument is of length zero"。改用 identical 后应安全跳过。
  msgs <- list(
    list(uuid = "x0", message = list(content = "no type here")),          # 缺 type
    list(type = "user", uuid = "u1", message = list(content = "hi there")) # 正常
  )
  expect_no_error(res <- f(msgs))
  expect_equal(length(res), 1L)  # 缺 type 的被跳过,只剩正常 user 消息
})

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

test_that(".claude_msgs_to_thread 用后续 user 轮的 tool_result 填真实结果/审批态", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(
    list(type = "assistant", uuid = "a1", message = list(content = list(
      list(type = "tool_use", id = "t1", name = "Bash", input = list(command = "ls")),
      list(type = "tool_use", id = "t2", name = "Bash", input = list(command = "rm x"))
    ))),
    list(type = "user", uuid = "u1", message = list(content = list(
      list(type = "tool_result", tool_use_id = "t1",
           content = "file1.txt\nfile2.txt", is_error = FALSE),
      list(type = "tool_result", tool_use_id = "t2",
           content = list(list(type = "text", text = "User denied tool execution")),
           is_error = TRUE)
    )))
  )
  out <- f(msgs)
  # user 轮只含 tool_result(无 text)→ 不渲染成 user 气泡,只剩 assistant 一条。
  expect_length(out, 1)
  parts <- out[[1]]$content
  expect_equal(parts[[1]]$result, "file1.txt\nfile2.txt")
  expect_false(parts[[1]]$isError)
  expect_equal(parts[[2]]$result, "User denied tool execution")
  expect_true(parts[[2]]$isError)
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

# ── 合成系统通知（resume 时 CLI 以 user 轮次写入的 <task-notification> 等）过滤 ──
test_that(".is_synthetic_system_user_text 识别 Claude Code 合成包装标签", {
  f <- shinyAssistantUI:::.is_synthetic_system_user_text
  expect_true(f("<task-notification>\n<status>stopped</status>\n</task-notification>"))
  expect_true(f("  <task-notification>x</task-notification>  "))
  expect_true(f("<system-reminder>be careful</system-reminder>"))
  expect_true(f("<local-command-stdout>ok</local-command-stdout>"))
  expect_true(f("<command-name>/compact</command-name>"))
  expect_true(f("<command-message>compacting</command-message>"))
  expect_true(f("<session-start-hook>hi</session-start-hook>"))
  expect_true(f("[Request interrupted by user for tool use]"))
  # 正常用户输入不应被判定为合成通知
  expect_false(f("请解释这段代码"))
  expect_false(f("what does <task-notification> mean as a concept?"))
  expect_false(f(""))
})

test_that(".claude_msgs_to_thread 过滤 <task-notification> 合成 user 气泡", {
  f <- shinyAssistantUI:::.claude_msgs_to_thread
  msgs <- list(
    list(type = "user", uuid = "u1", message = list(content = "真实用户提问")),
    list(type = "user", uuid = "sys1", message = list(content = list(
      list(type = "text", text = paste0(
        "<task-notification>\n<task-id>b4f7icfpc</task-id>\n",
        "<status>stopped</status>\n<summary>2 background shell tasks stopped</summary>\n",
        "</task-notification>"
      ))
    ))),
    list(type = "assistant", uuid = "a1", message = list(content = list(
      list(type = "text", text = "好的")
    )))
  )
  out <- f(msgs)
  # task-notification 不应成为气泡；真实 user + assistant 保留
  expect_length(out, 2)
  expect_equal(out[[1]]$role, "user")
  expect_equal(out[[1]]$content[[1]]$text, "真实用户提问")
  expect_equal(out[[2]]$role, "assistant")
})

# ── .prepend_quote(划词引用 blockquote 前置)────────────────────────────────
test_that(".prepend_quote 空引用原样返回", {
  f <- shinyAssistantUI:::.prepend_quote
  expect_identical(f("hello", ""), "hello")
  expect_identical(f("hello", NULL), "hello")
  expect_identical(f("hello", "   "), "hello")
})

test_that(".prepend_quote 单行引用前置为 blockquote", {
  f <- shinyAssistantUI:::.prepend_quote
  expect_identical(f("how to dedupe?", "join may duplicate rows"),
                   "> join may duplicate rows\n\nhow to dedupe?")
})

test_that(".prepend_quote 多行引用每行加 > ", {
  f <- shinyAssistantUI:::.prepend_quote
  expect_identical(f("q", "line1\nline2"), "> line1\n> line2\n\nq")
})

test_that(".prepend_quote 空文本 + 有引用也可用", {
  f <- shinyAssistantUI:::.prepend_quote
  expect_identical(f("", "quoted"), "> quoted\n\n")
  expect_identical(f(NULL, "quoted"), "> quoted\n\n")
})
