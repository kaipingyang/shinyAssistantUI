# Fixture：证明 R 端 assistant_tool_view() → argsView 注解 → 非内建工具名也能出富卡。
# 用自定义 handler(等价于 ellmer 透传路径:都汇于 on_tool_call(annotations=))。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  emit <- function(id, name, args, ann) {
    on_tool_call(id, name, args, annotations = c(list(defaultOpen = TRUE), ann))
    on_tool_result(id, "ok", is_error = FALSE)
  }
  on_chunk("custom tools:\n")
  # 非内建名 + R 声明 code(sql)
  emit("q1", "my_query", list(sql = "SELECT 1 FROM t"),
       assistant_tool_view("code", field = "sql", lang = "sql"))
  # 省略 field → 客户端默认 "code";lang r
  emit("q2", "my_runner", list(code = "z <- 3\nz * 2"),
       assistant_tool_view("code", lang = "r"))
  # 自定义字段的 diff
  emit("q3", "my_patch", list(before = "a <- 1", after = "a <- 2"),
       assistant_tool_view("diff", old_field = "before", new_field = "after"))
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "82vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
