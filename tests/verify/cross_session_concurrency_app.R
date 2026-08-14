library(shiny)
library(shinyAssistantUI)
library(promises)
library(later)

handler <- function(message, thread_id, on_chunk, on_done, on_tool_call,
                    on_tool_result, wait_for_approval, register_cancel, ...) {
  on_chunk(sprintf("%s:start:%s ", thread_id, message))
  if (grepl("approval", message, fixed = TRUE)) {
    tool_id <- paste0("approval-", thread_id)
    on_tool_call(
      tool_id, "Read", list(file_path = paste0("/tmp/", thread_id, ".txt")),
      list(requiresApproval = TRUE, title = paste("Approve", thread_id))
    )
    return(promises::then(
      wait_for_approval(tool_id),
      onFulfilled = function(value) {
        approved <- isTRUE(value$approved)
        on_tool_result(tool_id, if (approved) "approved" else "denied", !approved)
        on_chunk(sprintf("%s:approval:%s ", thread_id, approved))
        on_done()
        NULL
      }
    ))
  }

  promises::promise(function(resolve, reject) {
    settled <- FALSE
    finish <- function() {
      if (settled) return(invisible(NULL))
      settled <<- TRUE
      on_chunk(sprintf("%s:final:%s ", thread_id, message))
      on_done()
      resolve(NULL)
    }
    timer_cancel <- later::later(finish, delay = if (grepl("long", message, fixed = TRUE)) 3 else 1)
    register_cancel(function() {
      if (settled) return(invisible(NULL))
      settled <<- TRUE
      timer_cancel()
      resolve(NULL)
      invisible(NULL)
    })
  })
}
attr(handler, "supports_concurrent_threads") <- TRUE

history_loader <- function(session_id, thread_id, send_thread, ...) {
  send_thread(list(list(
    id = paste0("history-", thread_id), role = "assistant",
    content = list(list(type = "text", text = paste("History for", thread_id)))
  )))
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Plan 67 concurrency fixture"
)

server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    persistence = "server", on_session_load = history_loader,
    max_concurrent_runs = 2L
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "A", title = "Alpha", preview = "History A", createdAt = "2026-08-13T00:00:00Z"),
      list(id = "B", title = "Beta", preview = "History B", createdAt = "2026-08-13T00:00:01Z"),
      list(id = "C", title = "Gamma", preview = "History C", createdAt = "2026-08-13T00:00:02Z")
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
