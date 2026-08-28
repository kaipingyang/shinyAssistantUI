suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})

options(shinyAssistantUI.claude_idle_start_delay = 0)
project <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
state <- new.env(parent = emptyenv())
state$clients <- 0L
state$polls <- 0L
state$approvals <- 0L
state$denials <- 0L
state$interrupts <- 0L
state$history_reads <- 0L
state$branch <- shinyAssistantUI:::.addin_git_branch(project)
state$transcript <- list(list(
  id = "baseline", role = "assistant",
  content = list(list(type = "text", text = "Background baseline"))
))

result_message <- function(result = "complete") {
  ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "browser-session",
    result = result, usage = list()
  )
}

make_client <- function(options) {
  state$clients <- state$clients + 1L
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$get_server_info <- function() list(commands = list(), output_styles = list())
  client$approve_tool <- function(request_id, ...) {
    state$approvals <- state$approvals + 1L
    state$transcript <- list(list(
      id = "associated-reply", role = "assistant",
      content = list(list(
        type = "text",
        text = "Associated approval transcript persisted after Result."
      ))
    ))
    invisible(NULL)
  }
  client$deny_tool <- function(request_id, ...) {
    state$denials <- state$denials + 1L
    state$transcript <- list(list(
      id = "detached-reply", role = "assistant",
      content = list(list(
        type = "text",
        text = "Transcript reply published before detached approval stopped."
      ))
    ))
    invisible(NULL)
  }
  client$interrupt <- function(...) {
    state$interrupts <- state$interrupts + 1L
    invisible(NULL)
  }
  client$poll_messages <- function() {
    state$polls <- state$polls + 1L
    switch(as.character(state$polls),
      `1` = list(
        ClaudeAgentSDK::TaskStartedMessage(
          subtype = "task_started", data = list(), task_id = "browser-agent",
          description = "Browser-associated background task", uuid = "task-start",
          session_id = "browser-session", tool_use_id = "browser-task-tool",
          task_type = "Agent"
        ),
        result_message("foreground complete")
      ),
      `2` = list(ClaudeAgentSDK::PermissionRequestMessage(
        request_id = "browser-associated", tool_name = "Bash",
        tool_input = list(command = "echo browser-associated"),
        tool_use_id = "browser-task-tool", agent_id = "browser-agent",
        title = "Approve associated task"
      )),
      `3` = list(result_message("associated approval complete")),
      `4` = list(ClaudeAgentSDK::PermissionRequestMessage(
        request_id = "browser-detached", tool_name = "Bash",
        tool_input = list(command = "echo detached")
      )),
      list()
    )
  }
  client
}

testthat::local_mocked_bindings(
  .new_claude_options = function(...) list(...),
  .new_claude_client = make_client,
  .get_claude_session_messages = function(session_id, ...) {
    if (startsWith(session_id, "history-")) {
      return(list(
        list(id = paste0("u-", session_id), role = "user",
             content = list(list(type = "text", text = paste("History", session_id)))),
        list(id = paste0("a-", session_id), role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(list(type = "text", text = paste("Loaded", session_id))))
      ))
    }
    state$transcript
  },
  .claude_msgs_to_thread = function(messages, ...) messages,
  .claude_drain_timeout_seconds = function() 0.01,
  .package = "shinyAssistantUI",
  .env = globalenv()
)

session_map_path <- tempfile(fileext = ".rds")
handler <- make_claude_handler(
  options = list(permission_mode = "default", include_partial_messages = TRUE),
  session_map_path = session_map_path
)

ui <- fluidPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$div(
    style = "height:86vh;",
    assistantUIOutput("chat", height = "86vh")
  ),
  actionButton("clear_branch", "Clear branch"),
  actionButton("stale_branch", "Send stale branch"),
  tags$div(id = "client_count", textOutput("clients", inline = TRUE)),
  tags$div(id = "poll_count", textOutput("polls", inline = TRUE)),
  tags$div(id = "history_count", textOutput("history", inline = TRUE)),
  tags$div(id = "approval_count", textOutput("approvals", inline = TRUE)),
  tags$div(id = "denial_count", textOutput("denials", inline = TRUE)),
  tags$div(id = "interrupt_count", textOutput("interrupts", inline = TRUE)),
  tags$div(id = "expected_branch", textOutput("branch", inline = TRUE))
)

server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat", handler = handler, persistence = "server", show_thread_list = TRUE,
    working_dir = project, git_branch = state$branch,
    git_branch_provider = function(project) state$branch,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      state$history_reads <- state$history_reads + 1L
      send_thread(list(
        list(id = paste0("u-", session_id), role = "user",
             content = list(list(type = "text", text = paste("History", session_id)))),
        list(id = paste0("a-", session_id), role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(list(type = "text", text = paste("Loaded", session_id))))
      ), has_more = FALSE)
    }
  )

  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = lapply(seq_len(3L), function(index) list(
      id = paste0("history-", index), title = paste("History", index),
      preview = "Transcript only", createdAt = as.numeric(Sys.time()) * 1000 - index
    ))))
  }, once = TRUE)

  observeEvent(input$clear_branch, {
    ctrl$send_git_branch(project, NULL)
  })
  observeEvent(input$stale_branch, {
    ctrl$send_git_branch("/stale-project", "stale/branch")
  })

  output$clients <- renderText({ invalidateLater(200); state$clients })
  output$polls <- renderText({ invalidateLater(200); state$polls })
  output$history <- renderText({ invalidateLater(200); state$history_reads })
  output$approvals <- renderText({ invalidateLater(200); state$approvals })
  output$denials <- renderText({ invalidateLater(200); state$denials })
  output$interrupts <- renderText({ invalidateLater(200); state$interrupts })
  output$branch <- renderText({
    invalidateLater(200)
    if (is.null(state$branch)) "" else state$branch
  })
}

shinyApp(ui, server)
