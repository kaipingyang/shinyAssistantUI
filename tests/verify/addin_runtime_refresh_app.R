library(shiny)
library(shinyAssistantUI)

`%||%` <- function(x, y) if (is.null(x)) y else x

ui <- fluidPage(
  tags$div(
    style = "display:grid;grid-template-columns:2fr 1fr;gap:12px;height:82vh;",
    tags$div(assistantUIOutput("chat", height = "82vh")),
    tags$div(assistantUIOutput("plain", height = "82vh"))
  ),
  actionButton("service_ready", "fake service ready"),
  actionButton("commands_old", "old commands"),
  actionButton("commands_clear", "clear commands"),
  actionButton("commands_new", "new commands"),
  actionButton("task_start", "task start"),
  tags$div(id = "backend_count", textOutput("count", inline = TRUE)),
  tags$div(id = "backend_order", textOutput("order", inline = TRUE))
)

server <- function(input, output, session) {
  count <- reactiveVal(0L)
  order <- reactiveVal(character())
  handler <- function(message, on_chunk, on_done, on_tool_call, ...) {
    cat("[HANDLER]", message, "\n", file = stderr())
    count(isolate(count()) + 1L)
    order(c(isolate(order()), message))
    if (identical(message, "new checklist task")) {
      on_tool_call(
        "todo-live-pending", "TodoWrite",
        list(todos = list(list(
          content = "Live pending item", status = "in_progress",
          activeForm = "Working on live item"
        )))
      )
    } else if (identical(message, "complete checklist")) {
      on_tool_call(
        "todo-live-complete", "TodoWrite",
        list(todos = list(list(
          content = "Live pending item", status = "completed",
          activeForm = "Working on live item"
        )))
      )
    }
    on_chunk(paste0("reply:", message))
    on_done()
  }

  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    auto_start_copilot_api = TRUE,
    service_status = list(status = "checking", autoStart = TRUE),
    on_toggle_auto_start_copilot_api = function(value) invisible(value),
    on_retry_service = function() service$retry(),
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      todo_args <- list(todos = list(
        list(content = "Restored completed item A", status = "completed", activeForm = "Restoring completed item A"),
        list(content = "Restored completed item B", status = "completed", activeForm = "Restoring completed item B")
      ))
      send_thread(messages = list(
        list(id = "hist-u", role = "user",
             content = list(list(type = "text", text = "Historical checklist"))),
        list(id = "hist-a", role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(list(
               type = "tool-call", toolCallId = "todo-history", toolName = "TodoWrite",
               args = todo_args,
               argsText = as.character(jsonlite::toJSON(todo_args, auto_unbox = TRUE)),
               result = "Checklist updated", isError = FALSE
             )))
      ), has_more = FALSE)
    }
  )

  # Injected fake worker: polls a fixture-only flag and never calls the real home script.
  ready_path <- file.path(tempdir(), paste0("shinyAssistantUI-fake-copilot-ready-", Sys.getpid()))
  unlink(ready_path)
  worker <- new.env(parent = emptyenv())
  worker$is_alive <- function() !file.exists(ready_path)
  worker$get_result <- function() list(status = "ready", message = "fake copilot-api is ready")
  service <- shinyAssistantUI:::.new_copilot_service(
    auto_start = TRUE,
    publish = function(status) ctrl$send_service_status(status),
    worker_factory = function() worker,
    schedule = function(fn, delay) later::later(fn, delay = delay),
    poll_interval = 0.05
  )
  service$start()
  session$onSessionEnded(function() {
    service$dispose()
    unlink(ready_path)
  })

  assistantUIServer("plain", handler = handler)

  observeEvent(input$service_ready, { file.create(ready_path) })
  observeEvent(input$commands_old, {
    session$sendCustomMessage("chat_input:server-commands", list(
      commands = list(list(name = "oldcmd"), list(name = "removedcmd"))
    ))
  })
  observeEvent(input$commands_clear, {
    session$sendCustomMessage("chat_input:server-commands", list(commands = list()))
  })
  observeEvent(input$commands_new, {
    session$sendCustomMessage("chat_input:server-commands", list(
      commands = list(list(name = "newcmd"))
    ))
  })
  observeEvent(input$task_start, {
    session$sendCustomMessage("chat_input:task", list(
      taskId = "browser-task", kind = "started", description = "Browser task",
      status = "running"
    ))
  })

  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "checklist-history", title = "Checklist history",
           preview = "Historical checklist", createdAt = as.numeric(Sys.time()) * 1000)
    )))
  }, once = TRUE)

  output$count <- renderText(as.character(count()))
  output$order <- renderText(paste(order(), collapse = "|"))
}

shinyApp(ui, server)
