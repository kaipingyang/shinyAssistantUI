# Fixture：验证 markdown 渲染 —— 外链(target=_blank)、宽表格横向滚动、行内文件路径可点击打开。
library(shiny)
library(shinyAssistantUI)

`%||%` <- function(x, y) if (is.null(x)) y else x

md <- paste0(
  "See [the docs](https://example.com/guide) then open `R/app.R:12`.\n\n",
  "```r\nx <- 1:10\nmean(x)\n```\n\n",
  "```\nplain unlabeled block\n```\n\n",
  "| Mode | modules_select_dl source | modules_metadata source |\n",
  "|---|---|---|\n",
  "| non-group | run_module_select result | `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_very_long_unbreakable_cell` |\n"
)

handler <- function(message, on_chunk, on_done, ...) { lastmsg(message); on_chunk(md); on_done() }

ui <- assistantUIPage(
  div(style = "width: 620px;", assistantUIOutput("chat", height = "78vh")),
  verbatimTextOutput("probe"),
  verbatimTextOutput("ran"),
  verbatimTextOutput("lastmsg")
)
server <- function(input, output, session) {
  opened <- reactiveVal("")
  ran <- reactiveVal("")
  lastmsg <<- reactiveVal("")
  assistantUIServer(
    "chat", handler = handler,
    on_open_file = function(path, line = NULL) opened(paste0(path, ":", line %||% "")),
    # 模拟捕获:返回 list(ok/output),触发 :console-result → 前端自动把结果喂给 Claude。
    on_run_in_console = function(code) { ran(code); list(ok = TRUE, output = "RESULT_42", error = "") }
  )
  output$probe <- renderText(opened())
  output$ran <- renderText(ran())
  output$lastmsg <- renderText(lastmsg())
}
shinyApp(ui, server)
