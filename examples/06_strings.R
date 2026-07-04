library(shiny)
library(bslib)
devtools::load_all(here::here())

# 测试 strings 参数：对比默认英文 UI 与自定义中文 UI。
# 左栏 = 默认英文，右栏 = 全中文覆盖。
# hover 消息气泡可看到 tooltip 变化；点编辑/分支切换可看到按钮文字变化。

STRINGS_ZH <- list(
  thread = list(
    scrollToBottom = list(tooltip = "滚动到底部")
  ),
  threadList = list(
    new  = list(label = "新对话"),
    item = list(
      title  = list(fallback = "新对话"),
      archive = list(tooltip = "归档")
    )
  ),
  userMessage = list(
    edit = list(tooltip = "编辑消息")
  ),
  assistantMessage = list(
    reload   = list(tooltip = "重新生成"),
    copy     = list(tooltip = "复制"),
    feedback = list(
      positive = list(tooltip = "有帮助"),
      negative = list(tooltip = "没帮助")
    )
  ),
  editComposer = list(
    send   = list(label = "发送"),
    cancel = list(label = "取消")
  ),
  branchPicker = list(
    previous  = list(tooltip = "上一条"),
    `next`    = list(tooltip = "下一条")
  ),
  code = list(
    header = list(copy = list(tooltip = "复制代码"))
  )
)

DEMO_REPLY <- paste0(
  "这是一条示例回复，包含**加粗**、`行内代码`和代码块：\n\n",
  "```r\nx <- 1:10\nmean(x)\n```\n\n",
  "hover 气泡可以看到操作栏的 tooltip 变化。"
)

handler <- function(message, on_chunk, on_done, ...) {
  lines <- strsplit(DEMO_REPLY, "\n")[[1]]
  for (line in lines) {
    on_chunk(paste0(line, "\n"))
    Sys.sleep(0.01)
  }
  on_done()
}

ui <- page_fluid(
  h3("strings 参数测试：左栏默认英文，右栏中文"),
  layout_columns(
    col_widths = c(6, 6),
    card(
      card_header("默认英文（不传 strings）"),
      assistantUIOutput("chat_en", height = "70vh")
    ),
    card(
      card_header("中文 UI（传入 strings）"),
      assistantUIOutput("chat_zh", height = "70vh")
    )
  )
)

server <- function(input, output, session) {
  assistantUIServer("chat_en", handler = handler)
  assistantUIServer("chat_zh", handler = handler, strings = STRINGS_ZH)
}

shinyApp(ui, server)
