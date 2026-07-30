library(shiny)
library(shinyAssistantUI)
library(coro)

# 连续审批 auto-scroll 验证:先填屏,再连着弹 4 个需审批的工具,每个审批框出现应自动进视口。
handler <- coro::async(function(message, on_chunk, on_done, on_tool_call, wait_for_approval, ...) {
  for (i in 1:20) on_chunk(paste0("filler line ", i, " to overflow the viewport.\n"))
  for (k in 1:4) {
    tcid <- paste0("tc-", k)
    on_chunk(paste0("\ncalling tool ", k, "...\n"))
    on_tool_call(tcid, "Bash", list(command = paste0("echo step ", k)),
                 annotations = list(requiresApproval = TRUE))
    await(wait_for_approval(tcid))
    on_chunk(paste0("tool ", k, " approved.\n"))
  }
  on_done()
})

ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "55vh")))
server <- function(input, output, session) assistantUIServer("chat", handler = handler)
shinyApp(ui, server)
