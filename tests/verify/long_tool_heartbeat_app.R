library(shiny)

verify_lib <- Sys.getenv(
  "SHINYASSISTANTUI_VERIFY_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
library(shinyAssistantUI, lib.loc = verify_lib)

marker <- "synthetic-heartbeat-marker"

ui <- fluidPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$meta(
    name = "shinyassistant-heartbeat-package",
    content = paste0("installed-", as.character(packageVersion("shinyAssistantUI")))
  ),
  tags$div(
    style = "position:fixed;left:-10000px;top:-10000px",
    actionButton("start_fake", "Start synthetic activity"),
    actionButton("complete_fake", "Complete synthetic activity"),
    textOutput("fixture_ready", inline = TRUE)
  ),
  assistantUIOutput("chat", height = "96vh")
)

server <- function(input, output, session) {
  active_thread <- reactiveVal(NULL)
  active_run <- reactiveVal(NULL)
  finish_run <- NULL

  handler <- function(message, thread_id, run_id, on_error, ...) {
    base::message("[heartbeat-fixture] handler invoked")
    if (!identical(message, marker)) {
      on_error("Unexpected synthetic marker")
      return(invisible(NULL))
    }
    active_thread(thread_id)
    active_run(run_id)
    promises::promise(function(resolve, reject) {
      finish_run <<- resolve
    })
  }

  assistantUIServer("chat", handler = handler, persistence = "none")

  output$fixture_ready <- renderText(if (is.null(active_thread())) "waiting" else "ready")

  observeEvent(input$start_fake, {
    req(active_thread(), active_run())
    thread_id <- active_thread()
    run_id <- active_run()
    session$sendCustomMessage("chat_input:tool-call", list(
      toolCallId = "synthetic-bash-running",
      toolName = "Bash",
      args = list(command = "synthetic long-running command"),
      argsText = '{"command":"synthetic long-running command"}',
      annotations = list(icon = "terminal"),
      threadId = thread_id
    ))
    session$sendCustomMessage("chat_input:tool-call", list(
      toolCallId = "synthetic-agent-running",
      toolName = "Agent",
      args = list(description = "Synthetic exploration"),
      argsText = '{"description":"Synthetic exploration"}',
      annotations = list(icon = "search"),
      threadId = thread_id
    ))
    session$sendCustomMessage("chat_input:task", list(
      taskId = "synthetic-agent-task",
      kind = "started",
      description = "Synthetic subagent activity",
      status = "running",
      toolName = "Agent",
      threadId = thread_id,
      runId = run_id
    ))
  }, ignoreInit = TRUE)

  observeEvent(input$complete_fake, {
    req(active_thread(), active_run())
    thread_id <- active_thread()
    run_id <- active_run()
    session$sendCustomMessage("chat_input:tool-result", list(
      toolCallId = "synthetic-bash-running",
      result = "synthetic bash complete",
      isError = FALSE,
      threadId = thread_id
    ))
    session$sendCustomMessage("chat_input:tool-result", list(
      toolCallId = "synthetic-agent-running",
      result = "synthetic agent complete",
      isError = FALSE,
      threadId = thread_id
    ))
    session$sendCustomMessage("chat_input:task", list(
      taskId = "synthetic-agent-task",
      kind = "notification",
      description = "Synthetic subagent activity",
      status = "completed",
      toolName = "Agent",
      threadId = thread_id,
      runId = run_id
    ))
    session$sendCustomMessage("chat_input:done", list(
      suggestions = list(), threadId = thread_id, runId = run_id
    ))
    resolver <- finish_run
    finish_run <<- NULL
    active_thread(NULL)
    active_run(NULL)
    if (is.function(resolver)) session$onFlushed(function() resolver(NULL), once = TRUE)
  }, ignoreInit = TRUE)
}

shinyApp(ui, server)
