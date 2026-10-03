suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI, lib.loc = Sys.getenv("AUI_FOLLOW_LIBRARY"))
})

history_messages <- lapply(seq_len(90L), function(i) list(
  id = sprintf("follow-history-%03d", i),
  role = if (i %% 2L) "user" else "assistant",
  content = list(list(
    type = "text",
    text = paste0(
      sprintf("FOLLOW_HISTORY_%04d", i), " ",
      paste(rep("Synthetic older conversation for reading-anchor verification.", 3L), collapse = " ")
    )
  ))
))
base_text <- function(prefix, count) paste(vapply(seq_len(count), function(i) {
  paste0(sprintf("%s_%04d", prefix, i),
         " Synthetic content with enough height to make the conversation scroll.")
}, character(1)), collapse = "\n\n")
marker <- function(sequence) sprintf("FOLLOW_TAIL_%04d", sequence)
json_fragment <- function(text) {
  encoded <- as.character(jsonlite::toJSON(text, auto_unbox = TRUE))
  substr(encoded, 2L, nchar(encoded) - 1L)
}

ui <- bslib::page_fluid(
  tags$head(
    tags$link(rel = "icon", href = "data:,"),
    tags$meta(name = "follow-package-version", content = as.character(packageVersion("shinyAssistantUI")))
  ),
  assistantUIOutput("chat", height = "92vh"),
  div(style = "display:none", textOutput("fixture_state"))
)

server <- function(input, output, session) {
  fixture <- reactiveVal(list(scene = "idle", phase = "idle", sequence = 0L, done = TRUE))
  closed <- FALSE
  cancel_current <- NULL
  output$fixture_state <- renderText(as.character(jsonlite::toJSON(
    fixture(), auto_unbox = TRUE
  )))
  outputOptions(output, "fixture_state", suspendWhenHidden = FALSE)
  session$onSessionEnded(function() {
    closed <<- TRUE
    if (is.function(cancel_current)) cancel_current(FALSE)
  })

  handler <- function(message, thread_id, on_chunk, on_done, on_thinking,
                      on_tool_call_start, on_tool_call_delta, on_tool_call,
                      on_tool_result, on_proactive_messages, register_cancel, ...) {
    scene <- trimws(message)
    stopifnot(scene %in% c(
      "text-auto", "wheel-4", "wheel-40", "wheel-400", "keyboard-pageup", "scrollbar-drag",
      "tool-markdown", "reasoning-auto", "thinking-to-text", "canonical-replace"
    ))
    sequence <- 0L
    total <- 24L
    text <- ""
    timer <- NULL
    finished <- FALSE
    tool_id <- "follow-synthetic-write"

    promises::promise(function(resolve, reject) {
      publish <- function(phase, done = FALSE) {
        if (!closed) fixture(list(scene = scene, phase = phase, sequence = sequence, done = done))
      }
      finish <- function(notify = TRUE) {
        if (finished) return(invisible(NULL))
        finished <<- TRUE
        if (is.function(timer)) timer()
        timer <<- NULL
        if (notify && !closed) {
          if (scene == "tool-markdown") {
            on_tool_call_delta(tool_id, "\"}")
            on_tool_call(tool_id, "Write", list(file_path = "FOLLOW.md", content = text),
                         annotations = list(defaultOpen = TRUE))
            on_tool_result(tool_id, "Synthetic write completed; no filesystem operation was performed.")
          }
          on_done()
          publish("done", TRUE)
          if (scene == "canonical-replace") {
            later::later(function() {
              if (closed) return(invisible(NULL))
              on_proactive_messages(c(history_messages, list(
                list(id = "canonical-user", role = "user",
                     content = list(list(type = "text", text = message))),
                list(id = "canonical-assistant", role = "assistant",
                     status = list(type = "complete", reason = "stop"),
                     content = list(list(type = "text", text = text)))
              )), revision = 1L)
              publish("canonical-replaced", TRUE)
            }, delay = 0.35)
          }
        }
        cancel_current <<- NULL
        resolve(NULL)
        invisible(NULL)
      }
      cancel_current <<- finish
      register_cancel(function() finish(TRUE))
      emit <- function() {
        if (closed || finished) return(invisible(NULL))
        sequence <<- sequence + 1L
        initial <- sequence == 1L
        piece <- if (initial) {
          paste0(base_text("FOLLOW_BASE", 36L), "\n\n", marker(sequence), "\n\n")
        } else {
          paste0(
            "A new synthetic streaming paragraph is available. ",
            marker(sequence), "\n\n"
          )
        }
        if (scene == "thinking-to-text" && sequence == 2L) {
          piece <- paste0(base_text("FOLLOW_REPLY", 14L), "\n\n", marker(sequence), "\n\n")
        }
        if (scene == "tool-markdown") {
          if (initial) {
            on_tool_call_start(tool_id, "Write", annotations = list(defaultOpen = TRUE))
            on_tool_call_delta(tool_id, "{\"file_path\":\"FOLLOW.md\",\"content\":\"")
          }
          text <<- paste0(text, piece)
          on_tool_call_delta(tool_id, json_fragment(piece))
        } else if (scene == "reasoning-auto" || (scene == "thinking-to-text" && initial)) {
          on_thinking(piece)
        } else {
          text <<- paste0(text, piece)
          on_chunk(piece)
        }
        publish(if (initial) "quiet-streaming" else "growing")
        if (sequence >= total) {
          timer <<- later::later(function() finish(TRUE), 0.45)
        } else {
          timer <<- later::later(emit, if (initial) 2 else 0.12)
        }
        invisible(NULL)
      }
      emit()
    })
  }
  controls <- assistantUIServer(
    "chat", handler, show_thread_list = TRUE, persistence = "server",
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      send_thread(history_messages, has_more = FALSE)
    }
  )
  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(list(
      id = "follow-history", title = "Follow investigation history"
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
