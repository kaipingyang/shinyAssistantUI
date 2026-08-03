# Repro fixture:一段较长较快的流式输出 + 几次工具调用 + 末尾审批,用于在【流式进行中】
# 高频采样 viewport 滞后,判定自动贴底是否实时。
library(shiny); library(shinyAssistantUI); library(coro)
`%||%` <- function(x, y) if (is.null(x)) y else x
handler <- coro::async(function(message, on_chunk, on_done, on_tool_call, wait_for_approval, ...) {
  emit_tool <- function(i) {
    tcid <- paste0("t", i, "-", sample.int(1e6, 1))
    on_tool_call(tcid, paste0("Step", i), list(note = paste("running step", i)),
                 annotations = list(defaultOpen = TRUE))
  }
  for (i in 1:120) {
    on_chunk(sprintf("Streaming line %03d — filling the viewport to test real-time auto-scroll.\n", i))
    if (i %% 30 == 0) emit_tool(i %/% 30)   # 间插 4 次工具卡
    Sys.sleep(0.03)                          # ~3.6s 的流
  }
  tcid <- paste0("appr-", sample.int(1e6, 1))
  on_tool_call(tcid, "DangerTool", list(cmd = "rm -rf /tmp/x"),
               annotations = list(requiresApproval = TRUE, defaultOpen = TRUE, title = "Approve DangerTool?"))
  decision <- await(wait_for_approval(tcid))
  on_chunk(if (isTRUE(decision$approved)) "\napproved\n" else "\ndenied\n"); on_done()
})
ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "100vh")))
server <- function(input, output, session) assistantUIServer("chat", handler = handler)
shinyApp(ui, server)
