suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(promises)
  library(later)
})

projects <- c("/workspace/project-a", "/workspace/project-b")

workspace_handler <- function(message, thread_id, project, on_chunk, on_done,
                              on_task, ...) {
  task_id <- paste0("task-", thread_id)
  on_task(task_id, "started", paste("Work in", basename(project)), "running")
  on_chunk(sprintf("ROUTE[%s] %s", project, message))
  promises::promise(function(resolve, reject) {
    later::later(function() {
      on_task(task_id, "notification", paste("Finished", basename(project)), "completed")
      on_done()
      resolve(NULL)
    }, 1.5)
  })
}
attr(workspace_handler, "supports_concurrent_threads") <- TRUE

history_loader <- function(session_id, thread_id, project, send_thread, ...) {
  send_thread(list(list(
    id = paste0("history-", thread_id),
    role = "assistant",
    content = list(list(
      type = "text",
      text = sprintf("HISTORY[%s] restored for %s", project, session_id)
    ))
  )))
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Claude Workspace browser fixture"
)

server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler = workspace_handler,
    show_thread_list = TRUE,
    persistence = "server",
    workspace_mode = TRUE,
    working_dir = projects[[1L]],
    projects = projects,
    on_session_load = history_loader,
    max_concurrent_runs = 4L
  )
  session$onFlushed(function() {
    alpha_sessions <- c(
      list(list(
        id = "session-a", title = "Alpha session", preview = "A history",
        createdAt = "2026-08-14T00:00:00Z", project = projects[[1L]],
        projectLabel = "Project Alpha"
      )),
      lapply(seq_len(13L), function(i) list(
        id = sprintf("session-a-%02d", i),
        title = sprintf("Alpha history %02d", i),
        preview = sprintf("A history %02d", i),
        createdAt = sprintf("2026-08-14T00:00:%02dZ", i),
        project = projects[[1L]],
        projectLabel = "Project Alpha"
      ))
    )
    ctrl$send_sessions(list(sessions = c(
      alpha_sessions,
      list(list(
        id = "session-b", title = "Beta session", preview = "B history",
        createdAt = "2026-08-14T00:01:00Z", project = projects[[2L]],
        projectLabel = "Project Beta"
      ))
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
