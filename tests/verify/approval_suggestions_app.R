# Fixture：验证审批卡的 Always-allow(权限建议)+ Deny 并反馈文本。
# async handler 调 on_tool_call(requiresApproval + suggestions),await wait_for_approval,
# 把 UI 回传的 decision(approved/suggestionIdx/customMessage)写进 #decision 供无头断言。
library(shiny)
library(shinyAssistantUI)
library(coro)

`%||%` <- function(x, y) if (is.null(x)) y else x

suggestions <- list(
  list(type = "setMode", mode = "acceptEdits", destination = "session"),
  list(type = "addRules",
       rules = list(list(toolName = "Bash", ruleContent = "git status:*")),
       behavior = "allow", destination = "session")
)

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                wait_for_approval, ...) {
  tcid <- paste0("tc-", as.integer(Sys.time()), "-", sample.int(1e6, 1))
  on_chunk("checking...\n")
  on_tool_call(tcid, "Bash", list(command = "git status"),
               annotations = list(requiresApproval = TRUE, suggestions = suggestions))
  decision <- await(wait_for_approval(tcid))
  decrec(list(
    approved      = isTRUE(decision$approved),
    suggestionIdx = if (is.null(decision$suggestionIdx)) NA else decision$suggestionIdx,
    suggestionIdxs = decision$suggestionIdxs %||% NA,
    customMessage = decision$customMessage %||% NA
  ))
  on_chunk("done")
  on_done()
})

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "70vh")),
  verbatimTextOutput("decision")
)

server <- function(input, output, session) {
  decrec <<- reactiveVal(NULL)
  assistantUIServer("chat", handler = handler)
  output$decision <- renderText({
    d <- decrec()
    if (is.null(d)) return("none")
    as.character(jsonlite::toJSON(d, auto_unbox = TRUE))
  })
}

shinyApp(ui, server)
