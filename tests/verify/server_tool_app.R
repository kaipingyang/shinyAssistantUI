library(shiny)
library(shinyAssistantUI)

# Fixture:验证 ①服务端工具卡(serverTool 徽章)②审批卡片 title/displayName/description。
# 不接真实 LLM —— 直接用回调模拟 R handler 对 server_tool_use / PermissionRequestMessage
# 的输出契约(annotations)。真机数据形状待下游用真实 web_search/advisor 复核。
handler <- coro::async(function(message, on_chunk, on_done, on_tool_call, on_tool_result,
                    wait_for_approval, ...) {
  if (grepl("search", message, ignore.case = TRUE)) {
    # 服务端工具契约:serverTool=TRUE
    on_tool_call("st1", "web_search", args = list(query = "R shiny htmlwidget"),
                 annotations = list(serverTool = TRUE))
    on_tool_result("st1", "Found 3 results about R Shiny htmlwidgets.", is_error = FALSE)
    on_chunk("Based on the web search, here is the answer.")
    on_done()
  } else if (grepl("delete", message, ignore.case = TRUE)) {
    # 审批契约:title/displayName/description
    on_tool_call("ap1", "delete_file", args = list(path = "config.json"),
                 annotations = list(
                   requiresApproval = TRUE,
                   title       = "Delete config.json?",
                   displayName = "File Deletion",
                   description = "This permanently removes the file from disk."
                 ))
    d <- coro::await(wait_for_approval("ap1"))
    if (isTRUE(d$approved)) {
      on_tool_result("ap1", "File deleted successfully.", is_error = FALSE)
      on_chunk("Done. Deletion approved and completed.")
    } else {
      on_tool_result("ap1", "Denied by user", is_error = TRUE)
      on_chunk("Cancelled.")
    }
    on_done()
  } else {
    on_chunk("Say 'search' for a server tool, 'delete' for an approval.")
    on_done()
  }
})

ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
