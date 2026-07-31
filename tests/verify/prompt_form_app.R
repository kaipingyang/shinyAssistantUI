# Fixture (Plan 47 B):PromptUser 交互表单 UI→updated_input 回传路径(自定义 handler,不需真 CLI)。
library(shiny)
library(shinyAssistantUI)
library(coro)
`%||%` <- function(x, y) if (is.null(x)) y else x

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                wait_for_approval, ...) {
  tcid <- paste0("pf-", as.integer(Sys.time()), "-", sample.int(1e6, 1))
  fields <- list(
    list(name = "test", type = "radio", label = "Test method",
         options = list("t-test", "ANOVA", "Wilcoxon"), default = "t-test"),
    list(name = "alpha", type = "slider", label = "alpha", min = 0, max = 1, step = 0.01, default = 0.05)
  )
  on_chunk("choose params...\n")
  on_tool_call(tcid, "PromptUser", list(title = "Analysis params", fields = fields),
               annotations = list(requiresApproval = TRUE, defaultOpen = TRUE))
  decision <- await(wait_for_approval(tcid))
  decrec(as.character(jsonlite::toJSON(decision$updatedInput %||% NA, auto_unbox = TRUE)))
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
