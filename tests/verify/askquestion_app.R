# Fixture:验证 AskUserQuestion 交互卡 UI→答案回传路径(自定义 handler,不需真 CLI)。
library(shiny)
library(shinyAssistantUI)
library(coro)
`%||%` <- function(x, y) if (is.null(x)) y else x

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                wait_for_approval, ...) {
  tcid <- paste0("ask-", as.integer(Sys.time()), "-", sample.int(1e6, 1))
  qs <- list(
    list(question = "Fav color?", header = "Color", multiSelect = FALSE,
         options = list(list(label = "Red"), list(label = "Blue"))),
    list(question = "Which langs?", header = "Langs", multiSelect = TRUE,
         options = list(list(label = "R"), list(label = "Python")))
  )
  on_chunk("asking...\n")
  on_tool_call(tcid, "AskUserQuestion", list(questions = qs),
               annotations = list(requiresApproval = TRUE, defaultOpen = TRUE))
  decision <- await(wait_for_approval(tcid))
  decrec(as.character(jsonlite::toJSON(decision$answers %||% NA, auto_unbox = TRUE)))
  on_chunk("done"); on_done()
})

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "70vh")),
  verbatimTextOutput("decision")
)
server <- function(input, output, session) {
  decrec <<- reactiveVal(NULL)
  assistantUIServer("chat", handler = handler)
  output$decision <- renderText(decrec() %||% "none")
}
shinyApp(ui, server)
