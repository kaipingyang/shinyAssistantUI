# Fixture：一条 assistant 消息内发多种工具 tool-call,验证参数区富渲染
# (Edit→diff / Bash→bash / Write→python / run_r→r / 未知→json)。defaultOpen 让卡展开。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  emit <- function(id, name, args) {
    on_tool_call(id, name, args, annotations = list(defaultOpen = TRUE))
    on_tool_result(id, "ok", is_error = FALSE)
  }
  on_chunk("running tools:\n")
  emit("e1", "Edit", list(file_path = "a.R", old_string = "x <- 1", new_string = "x <- 2"))
  emit("b1", "Bash", list(command = "ls -la /tmp"))
  emit("w1", "Write", list(file_path = "f.py", content = "print(1)"))
  emit("r1", "mcp__r_session__run_r", list(code = "y <- 2\nmean(y)"))
  emit("u1", "Mystery", list(foo = 1, bar = list(2, 3)))
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "82vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
