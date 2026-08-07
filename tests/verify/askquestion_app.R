# Fixture:验证 AskUserQuestion 交互卡 UI→答案回传路径(自定义 handler,不需真 CLI)。
library(shiny)
library(shinyAssistantUI)
library(coro)
`%||%` <- function(x, y) if (is.null(x)) y else x

qs <- list(
  list(question = "Fav color?", header = "Color", multiSelect = FALSE,
       options = list(list(label = "Red"), list(label = "Blue"))),
  list(question = "Which langs?", header = "Langs", multiSelect = TRUE,
       options = list(list(label = "R"), list(label = "Python")))
)

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                wait_for_approval, ...) {
  tcid <- paste0("ask-", as.integer(Sys.time()), "-", sample.int(1e6, 1))
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
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      args <- list(
        questions = qs,
        answers = list("Fav color?" = "Teal", "Which langs?" = c("R", "SQL"))
      )
      send_thread(messages = list(
        list(id = "hist-ask-u", role = "user",
             content = list(list(type = "text", text = "Historical AskUserQuestion"))),
        list(id = "hist-ask-a", role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(
               list(type = "tool-call", toolCallId = "hist-ask-tool",
                    toolName = "AskUserQuestion", args = args,
                    argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
                    result = "Answers submitted", isError = FALSE,
                    artifact = list(defaultOpen = TRUE, approvalResult = "approved")),
               list(type = "text", text = "Historical answers restored")
             ))
      ), has_more = FALSE)
    }
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "ask-history", title = "Ask history",
           preview = "Historical AskUserQuestion", createdAt = as.numeric(Sys.time()) * 1000)
    )))
  }, once = TRUE)
  output$decision <- renderText(decrec() %||% "none")
}
shinyApp(ui, server)
