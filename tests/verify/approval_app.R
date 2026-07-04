library(shiny)
library(bslib)
library(promises)
devtools::load_all(here::here(), quiet = TRUE)

# 需审批工具:发 requiresApproval 卡片,await 用户决策,据结果发 result。
approval_handler <- function(message, on_chunk, on_done, on_tool_call,
                             on_tool_result, wait_for_approval, ...) {
  on_tool_call(
    "appr-1", "delete_file",
    args        = list(path = "/tmp/important.txt"),
    annotations = list(title = "delete_file", requiresApproval = TRUE, icon = "wrench")
  )
  p <- wait_for_approval("appr-1")
  promises::then(p, function(msg) {
    if (isTRUE(msg$approved)) {
      on_tool_result("appr-1", "File deleted successfully", is_error = FALSE)
      on_chunk("Deletion approved and completed.")
    } else {
      on_tool_result("appr-1", "Denied by user", is_error = TRUE)
      on_chunk("Deletion cancelled.")
    }
    on_done()
  })
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = approval_handler)
}
shinyApp(ui, server)
