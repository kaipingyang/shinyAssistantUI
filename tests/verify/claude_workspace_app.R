suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(promises)
  library(later)
})

projects <- c(
  "/workspace/project-a",
  "/workspace/project-b",
  "/workspace/project-d",
  "/workspace/project-e"
)
new_project <- "/workspace/project-c"
initial_favorites <- c(
  "/favorites/item-10",
  "/workspace/project-b",
  "/favorites/item-2"
)

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
  state <- new.env(parent = emptyenv())
  state$favorites <- initial_favorites
  state$selected <- projects[[1L]]

  project_sessions <- function(project) {
    if (identical(project, projects[[1L]])) {
      return(c(
        list(list(
          id = "session-a", title = "Alpha session", preview = "A history",
          createdAt = "2026-08-14T00:00:00Z", project = project,
          projectLabel = "Project Alpha"
        )),
        lapply(seq_len(13L), function(i) list(
          id = sprintf("session-a-%02d", i),
          title = sprintf("Alpha history %02d", i),
          preview = sprintf("A history %02d", i),
          createdAt = sprintf("2026-08-14T00:00:%02dZ", i),
          project = project,
          projectLabel = "Project Alpha"
        ))
      ))
    }
    if (identical(project, projects[[2L]])) {
      return(list(list(
        id = "session-b", title = "Beta session", preview = "B history",
        createdAt = "2026-08-14T00:01:00Z", project = project,
        projectLabel = "Project Beta"
      )))
    }
    if (identical(project, projects[[3L]])) {
      return(list(list(
        id = "session-d", title = "Delta session", preview = "D history",
        createdAt = "2026-08-14T00:03:00Z", project = project,
        projectLabel = "Project Delta"
      )))
    }
    if (identical(project, new_project)) {
      return(list(list(
        id = "session-c", title = "Gamma session", preview = "C history",
        createdAt = "2026-08-14T00:02:00Z", project = project,
        projectLabel = "Project Gamma"
      )))
    }
    list()
  }
  state$registry <- shinyAssistantUI:::.workspace_project_activity_order(
    projects,
    unlist(lapply(projects, project_sessions), recursive = FALSE),
    current = projects[[1L]]
  )
  build_sessions <- function() {
    unlist(lapply(state$registry, project_sessions), recursive = FALSE)
  }
  push_sessions <- function() {
    ctrl$send_sessions(list(
      sessions = build_sessions(),
      projectOrder = as.list(state$registry)
    ))
  }

  ctrl <- assistantUIServer(
    "chat",
    handler = workspace_handler,
    show_thread_list = TRUE,
    persistence = "server",
    workspace_mode = TRUE,
    working_dir = projects[[1L]],
    native_picker = FALSE,
    # The UI payload is explicit Favorites only, not the Workspace registry.
    projects = state$favorites,
    on_set_working_dir = function(path) {
      state$selected <- path
      if (!path %in% state$registry) {
        state$registry <- c(path, state$registry)
      }
      ctrl$send_working_dir(path, list())
      ctrl$send_projects(state$favorites)
      push_sessions()
    },
    on_save_project = function() {
      state$favorites <- unique(c(state$selected, state$favorites))
      ctrl$send_projects(state$favorites)
    },
    on_remove_project = function(path) {
      state$favorites <- setdiff(state$favorites, path)
      ctrl$send_projects(state$favorites)
      # Deliberately retain state$registry and all project sessions.
    },
    on_session_load = history_loader,
    max_concurrent_runs = 4L
  )
  session$onFlushed(function() push_sessions(), once = TRUE)
}

shinyApp(ui, server)
