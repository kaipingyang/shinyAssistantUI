library(shiny); library(shinyAssistantUI); library(later)
# 流式若干文字 → tool 调用 + 大结果(增量,later 间隔),验证 viewport 自动滚到底。
handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  step <- 0
  tick <- function() {
    step <<- step + 1
    if (step <= 30) { on_chunk(paste0("Filler line ", step, " pushing content beyond the fold.\n")); later::later(tick, 0.06) }
    else if (step == 31) { on_tool_call("tc-scroll", "Bash", list(command = "seq 1 50")); later::later(tick, 0.2) }
    else if (step == 32) { on_tool_result("tc-scroll", paste(c(sprintf("out %d", 1:50), "BOTTOM_MARKER"), collapse = "\n"), is_error = FALSE); later::later(tick, 0.2) }
    else { on_chunk("\nTAIL_AFTER_TOOL"); on_done() }
  }
  tick()
}
ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "70vh")))
server <- function(input, output, session) assistantUIServer("chat", handler = handler)
shinyApp(ui, server)
