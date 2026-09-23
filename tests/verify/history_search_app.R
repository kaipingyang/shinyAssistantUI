suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinyAssistantUI)
})

projects <- paste0("/synthetic/project-", letters[1:4])
catalog <- function() {
  items <- lapply(seq_len(2000L), function(i) list(
    id = sprintf("history-%04d", i),
    title = sprintf("History %04d", i),
    preview = paste("Existing preview", i, paste(rep("local metadata", 12L), collapse = " ")),
    createdAt = "2026-09-01T00:00:00Z",
    project = projects[[1L + (i - 1L) %% length(projects)]],
    archived = FALSE
  ))
  items[[2000L]]$title <- "History target [a.*] \u4e2d\u6587"
  items[[1999L]]$preview <- "Needle-preview in an old conversation"
  c(items, list(list(
    id = "archived-target", title = "Archived target",
    preview = "Needle-preview in archived history",
    createdAt = "2026-08-01T00:00:00Z", project = projects[[4L]], archived = TRUE
  )))
}
saved <- new.env(parent = emptyenv())
saved$chat <- catalog()
saved$workspace <- catalog()

ui <- page_fluid(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$style("body { margin: 0; } #search-probe { display:none; }"),
  tags$script(HTML(
    "Shiny.addCustomMessageHandler('history-search-probe', p => {document.getElementById('search-probe').textContent=JSON.stringify(p);});"
  )),
  tags$div(id = "search-probe"),
  layout_columns(
    col_widths = c(6, 6),
    assistantUIOutput("chat", height = "94vh"),
    assistantUIOutput("workspace", height = "94vh")
  )
)

server <- function(input, output, session) {
  query <- isolate(parseQueryString(session$clientData$url_search))
  previews <- !identical(query$previews, "0")
  state <- saved
  if (identical(query$mode, "benchmark")) {
    state <- new.env(parent = emptyenv())
    state$chat <- catalog()
    state$workspace <- catalog()
  }
  probe <- list(loads = list(), submissions = 0L, renamed = "", archived = "", deleted = "")
  publish_probe <- function() session$sendCustomMessage("history-search-probe", probe)
  bind_widget <- function(id, workspace) {
    push <- function() {
      items <- lapply(state[[id]], function(item) {
        if (!previews) item$preview <- ""
        if (!workspace) item$project <- NULL
        item
      })
      ctrl$send_sessions(list(sessions = items, projectOrder = as.list(c(projects, "/synthetic/empty"))))
    }
    ctrl <- assistantUIServer(
      id,
      show_thread_list = TRUE,
      persistence = "server",
      workspace_mode = workspace,
      working_dir = if (workspace) projects[[1L]] else NULL,
      handler = function(message, on_chunk, on_done, ...) {
        probe$submissions <<- probe$submissions + 1L
        publish_probe()
        on_chunk("SEARCH_FIXTURE_STREAM_START\n")
        promises::promise(function(resolve, reject) {
          later::later(function() {
            on_chunk("\nSEARCH_FIXTURE_STREAM_DONE")
            on_done()
            resolve(NULL)
          }, 0.8)
        })
      },
      on_session_load = function(session_id, thread_id, send_thread, ...) {
        probe$loads[[length(probe$loads) + 1L]] <<- list(widget = id, id = session_id)
        publish_probe()
        send_thread(list(
          list(id = paste0(thread_id, "-user"), role = "user",
               content = list(list(type = "text", text = paste("Historical request", session_id)))),
          list(id = paste0(thread_id, "-tool"), role = "assistant",
               content = list(list(
                 type = "tool-call", toolCallId = paste0(thread_id, "-read"), toolName = "Read",
                 args = list(file_path = "/synthetic/readme.R"),
                 argsText = as.character(jsonlite::toJSON(list(file_path = "/synthetic/readme.R"), auto_unbox = TRUE)),
                 result = "Synthetic historical tool result"
               ))),
          list(id = paste0(thread_id, "-answer"), role = "assistant",
               content = list(list(type = "text", text = paste0(
                 "RESTORED[", session_id, "] [Documentation](https://example.invalid/docs)"
               ))))
        ))
      },
      on_rename = function(thread_id, title) {
        state[[id]] <- lapply(state[[id]], function(item) {
          if (identical(item$id, thread_id)) item$title <- title
          item
        })
        probe$renamed <<- paste(id, thread_id, title, sep = "|")
        publish_probe()
        push()
      },
      on_archive_session = function(session_id, archived) {
        state[[id]] <- lapply(state[[id]], function(item) {
          if (identical(item$id, session_id)) item$archived <- archived
          item
        })
        probe$archived <<- paste(id, session_id, archived, sep = "|")
        publish_probe()
        push()
      },
      on_delete_session = function(session_id) {
        state[[id]] <- Filter(function(item) !identical(item$id, session_id), state[[id]])
        probe$deleted <<- paste(id, session_id, sep = "|")
        publish_probe()
        push()
      }
    )
    session$onFlushed(function() { push(); publish_probe() }, once = TRUE)
  }
  bind_widget("chat", FALSE)
  bind_widget("workspace", TRUE)
}
shinyApp(ui, server)
