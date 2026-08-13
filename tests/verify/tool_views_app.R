# Fixture：一条 assistant 消息内发多种工具 tool-call，验证参数区富渲染。
# 覆盖 Edit/Bash、代码 Write、CSV/TSV 表格、TXT 富文本、Markdown、run_r 与 JSON fallback。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result,
                    on_tool_call_start, on_tool_call_delta, ...) {
  emit <- function(id, name, args, result = "ok") {
    on_tool_call(id, name, args, annotations = list(defaultOpen = TRUE))
    on_tool_result(id, result, is_error = FALSE)
  }
  on_chunk("running tools:\n")
  on_tool_call_start(
    "w-stream", "Write",
    annotations = list(defaultOpen = TRUE)
  )
  on_tool_call_delta(
    "w-stream",
    '{"file_path":"STREAM.md","content":"# Streaming preview\\n\\n- first'
  )
  later::later(function() {
    on_tool_call_delta("w-stream", '\\n- second')
  }, delay = 0.7)
  emit("e1", "Edit", list(file_path = "a.R", old_string = "x <- 1", new_string = "x <- 2"))
  emit(
    "b1", "Bash", list(command = "ls -la /tmp"),
    paste(sprintf("bash result line %03d", seq_len(200)), collapse = "\n")
  )
  emit("w-py", "Write", list(file_path = "f.py", content = "print(1)"))
  emit("w-r", "Write", list(file_path = "analysis.R", content = "x <- mean(1:3)"))
  emit("w-csv", "Write", list(
    file_path = "people.csv",
    content = "name,note\r\nAlice,\"hello, \"\"world\"\"\"\r\nHTML,<script>alert(1)</script>\r\n"
  ))
  emit("w-tsv", "Write", list(
    path = "D:\\data\\people.TSV",
    content = "name\tnote\nAlice\thello, world\n"
  ))
  emit("w-txt", "Write", list(
    file_path = "notes.txt",
    content = "# Rich note\n\n- first item\n"
  ))
  emit("w-md", "Write", list(
    file_path = "README.md",
    content = "## Markdown write\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
  ))
  # run_r:给一段文本结果,验证结果区 console 化(纯文本、非 JSON)。
  on_tool_call("r1", "mcp__r_session__run_r", list(code = "y <- 2\nmean(y)"),
               annotations = list(defaultOpen = TRUE))
  on_tool_result("r1", "[1] 2\n", is_error = FALSE)
  emit("t1", "TodoWrite", list(todos = list(
    list(content = "write tests", status = "completed", activeForm = "writing tests"),
    list(content = "ship it", status = "in_progress", activeForm = "shipping it")
  )))
  emit("g1", "Grep", list(pattern = "TODO", path = "src", output_mode = "content"))
  emit("wf1", "WebFetch", list(url = "https://example.com/guide", prompt = "summarize"))
  emit("u1", "Mystery", list(foo = 1, bar = list(2, 3)))
  later::later(function() {
    on_tool_call_delta("w-stream", '\\n- final\\n"}')
    on_tool_call(
      "w-stream", "Write",
      list(
        file_path = "STREAM.md",
        content = "# Streaming preview\n\n- first\n- second\n- final\n"
      ),
      annotations = list(defaultOpen = TRUE)
    )
    on_tool_result("w-stream", "ok", is_error = FALSE)
    on_done()
  }, delay = 1.8)
}

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "82vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
