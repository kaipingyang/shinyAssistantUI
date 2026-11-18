# Plan 165 fixture: Claude Code 2.1.3xx AskUserQuestion extended schema
# (title, kind text/number/choice, description, placeholder, number bounds).
suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(coro)
})
`%||%` <- function(x, y) if (is.null(x)) y else x

ask_args <- list(
  title = "Before I build your deck",
  questions = list(
    list(question = "What is the deck about?", header = "Topic", kind = "text",
         description = "One sentence is enough.", placeholder = "e.g. Q3 results"),
    list(question = "How many slides?", header = "Length", kind = "number",
         min = 3, max = 20, step = 1, defaultValue = 8, unit = "slides"),
    list(question = "Which style?", header = "Style", kind = "choice", multiSelect = FALSE,
         options = list(list(label = "Minimal"), list(label = "Bold", description = "Large type")))
  )
)

handler <- coro::async(function(message, on_chunk, on_done, on_tool_call,
                                on_tool_result, wait_for_approval, ...) {
  id <- paste0("ask-ext-", sample.int(1e6, 1))
  on_chunk("asking...\n")
  on_tool_call(id, "AskUserQuestion", ask_args,
               annotations = list(requiresApproval = TRUE, defaultOpen = TRUE))
  decision <- await(wait_for_approval(id))
  decrec(as.character(jsonlite::toJSON(decision$answers %||% NA, auto_unbox = TRUE)))
  on_tool_result(id, "Answers submitted", is_error = FALSE)
  on_chunk("done")
  on_done()
})

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "88vh"),
  div(style = "display:none", verbatimTextOutput("decision"))
)

server <- function(input, output, session) {
  decrec <<- reactiveVal(NULL)
  output$decision <- renderText(decrec() %||% "none")
  outputOptions(output, "decision", suspendWhenHidden = FALSE)
  ctrl <- assistantUIServer(
    "chat", handler = handler, persistence = "server", show_thread_list = TRUE,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      args <- c(ask_args, list(answers = list(
        "What is the deck about?" = "Board update", "How many slides?" = "6",
        "Which style?" = "Minimal")))
      send_thread(messages = list(
        list(id = "hist-deck-u", role = "user",
             content = list(list(type = "text", text = "Historical deck questions"))),
        list(id = "hist-deck-a", role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(
               list(type = "tool-call", toolCallId = "hist-deck-tool",
                    toolName = "AskUserQuestion", args = args,
                    argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
                    result = "Answers submitted", isError = FALSE,
                    artifact = list(defaultOpen = TRUE, approvalResult = "approved")),
               list(type = "text", text = "Historical deck answers restored")
             ))
      ), has_more = FALSE)
    }
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "deck-history", title = "Deck history",
           preview = "Historical deck questions", createdAt = as.numeric(Sys.time()) * 1000)
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
