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
  tags$div(id = "backend_order", textOutput("order", inline = TRUE)),
  tags$div(id = "retry_count", textOutput("retries", inline = TRUE))
)

server <- function(input, output, session) {
  count <- reactiveVal(0L)
  order <- reactiveVal(character())
  handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, on_usage, ...) {
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
    } else if (identical(message, "many checklist tasks")) {
      on_tool_call(
        "todo-live-many", "TodoWrite",
        list(todos = lapply(seq_len(11), function(i) list(
          content = sprintf("Current task %02d", i),
          status = if (i == 1L) "in_progress" else "pending",
          activeForm = sprintf("Working on current task %02d", i)
        )))
      )
    } else if (identical(message, "new current task group")) {
      on_tool_call(
        "task-current-create", "TaskCreate",
        list(subject = "Fresh current task", activeForm = "Working on fresh current task")
      )
      on_tool_result("task-current-create", list(taskId = "fresh-current"), is_error = FALSE)
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
    on_usage(cost_usd = 1.4781, tokens = 78022L, turns = 1L, duration_ms = 7500L)
    on_done()
  }

  history_state <- new.env(parent = emptyenv())
  history_state$reads <- 0L
  history_state$raw <- list(
    list(type = "user", uuid = "hist-u", message = list(content = "Historical checklist")),
    list(type = "assistant", uuid = "hist-a", message = list(content = list(list(
      type = "tool_use", id = "todo-history", name = "TodoWrite",
      input = list(todos = list(
        list(content = "Restored completed item A", status = "completed", activeForm = "Restoring completed item A"),
        list(content = "Restored completed item B", status = "completed", activeForm = "Restoring completed item B")
      ))
    ))))
  )
  mock_scope <- new.env(parent = environment())
  testthat::local_mocked_bindings(
    .get_claude_session_messages = function(session_id) {
      history_state$reads <- history_state$reads + 1L
      history_state$raw
    },
    .package = "shinyAssistantUI",
    .env = mock_scope
  )
  history_loader <- make_claude_session_loader(tempfile(fileext = ".rds"))
  load_growing_history <- function(session_id, thread_id, send_thread,
                                   cursor = NULL, limit = 50L, ...) {
    history_loader(session_id, thread_id, send_thread, cursor = cursor, limit = limit)
    if (is.null(cursor) && history_state$reads == 1L) {
      history_state$raw <- c(history_state$raw, list(
        list(type = "user", uuid = "hist-task", message = list(content = paste0(
          "<task-notification><task-id>background-1</task-id>",
          "<status>completed</status></task-notification>"
        ))),
        list(type = "assistant", uuid = "hist-late-read", message = list(content = list(list(
          type = "tool_use", id = "read-late", name = "Read",
          input = list(file_path = "functions/process_sdtm_data.R")
        )))),
        list(type = "assistant", uuid = "hist-thinking", message = list(content = list(list(
          type = "thinking", thinking = "Continue after the completed task"
        ))))
      ))
    }
  }

  retry_count <- reactiveVal(0L)
  # Fixture-only health flag and no-op launcher. Automated verification never
  # invokes or modifies the real ~/auto-start-copilot.sh.
  ready_path <- file.path(tempdir(), paste0("shinyAssistantUI-fake-copilot-ready-", Sys.getpid()))
  unlink(ready_path)
  copilot_plugin <- shinyAssistantUI:::.new_copilot_addin_plugin(
    auto_start = TRUE,
    service_factory = function(auto_start, publish) {
      service <- shinyAssistantUI:::.new_copilot_service(
        auto_start = auto_start,
        publish = publish,
        health = function() file.exists(ready_path),
        launch = function() invisible(0L),
        script_exists = function(path) TRUE,
        script_executable = function(path) TRUE,
        schedule = function(fn, delay) later::later(fn, delay = delay),
        timeout = 0.35,
        poll_interval = 0.05
      )
      retry <- service$retry
      service$retry <- function() {
        retry_count(isolate(retry_count()) + 1L)
        retry()
      }
      service
    }
  )
  chat_handler <- handler
  attr(chat_handler, "ui_addons") <- list(copilotService = copilot_plugin$config())
  ctrl <- assistantUIServer(
    "chat",
    handler = chat_handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_session_load = load_growing_history
  )
  copilot_plugin$bind(session, "chat_input")
  session$onSessionEnded(function() unlink(ready_path))

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
           preview = "Historical checklist", createdAt = as.numeric(Sys.time()) * 1000),
      list(id = "draft-history-b", title = "Draft history B",
           preview = "Second restored session", createdAt = as.numeric(Sys.time()) * 1000 - 1000)
    )))
  }, once = TRUE)

  output$count <- renderText(as.character(count()))
  output$order <- renderText(paste(order(), collapse = "|"))
  output$retries <- renderText(as.character(retry_count()))
}

shinyApp(ui, server)
