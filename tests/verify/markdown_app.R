# Fixture：验证 markdown 渲染 —— 外链(target=_blank)、宽表格横向滚动、行内文件路径可点击打开。
library(shiny)
library(bslib)
library(shinyAssistantUI)

`%||%` <- function(x, y) if (is.null(x)) y else x

md <- paste0(
  "See [the docs](https://example.com/guide) then open `R/app.R:12`.\n\n",
  "```r\nx <- 1:10\nmean(x)\n```\n\n",
  "| Mode | modules_select_dl source | modules_metadata source |\n",
  "|---|---|---|\n",
  "| non-group | run_module_select result | `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_very_long_unbreakable_cell` |\n"
)

handler <- function(message, on_chunk, on_done, ...) { on_chunk(md); on_done() }

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  div(style = "width: 620px;", assistantUIOutput("chat", height = "78vh")),
  verbatimTextOutput("probe"),
  verbatimTextOutput("ran")
)
server <- function(input, output, session) {
  opened <- reactiveVal("")
  ran <- reactiveVal("")
  assistantUIServer(
    "chat", handler = handler,
    on_open_file = function(path, line = NULL) opened(paste0(path, ":", line %||% "")),
    on_run_in_console = function(code) ran(code)
  )
  output$probe <- renderText(opened())
  output$ran <- renderText(ran())
}
shinyApp(ui, server)
