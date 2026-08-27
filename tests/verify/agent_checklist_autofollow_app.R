library(shiny)

verify_lib <- Sys.getenv(
  "SHINYASSISTANTUI_VERIFY_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
library(shinyAssistantUI, lib.loc = verify_lib)

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$meta(
    name = "shinyassistant-behavior-package",
    content = paste0("installed-", as.character(packageVersion("shinyAssistantUI")))
  ),
  tags$div(
    style = "position:fixed;left:-10000px;top:-10000px",
    actionButton("fake_chunk", "Append synthetic chunk"),
    actionButton("fake_done", "Complete synthetic turn"),
    textOutput("fixture_ready", inline = TRUE)
  ),
  assistantUIOutput("chat", height = "100%")
)

server <- function(input, output, session) {
  active <- new.env(parent = emptyenv())
  active$turn <- 0L
  active$chunk <- 0L
  fixture_ready <- reactiveVal("0:0")

  handler <- function(message, on_chunk, on_done, on_error,
                      on_tool_call, on_tool_result, ...) {
    base::message("[behavior-fixture] handler invoked")
    turn <- active$turn + 1L
    active$turn <- turn
    active$chunk <- 0L
    fixture_ready(paste(turn, 0L, sep = ":"))
    active$on_chunk <- on_chunk
    active$on_done <- on_done

    if (turn == 1L) {
      for (index in 1:2) {
        tool_id <- paste0("synthetic-agent-", index)
        on_tool_call(
          tool_call_id = tool_id,
          tool_name = "Agent",
          args = list(description = paste("Synthetic agent", index)),
          annotations = list(icon = "search")
        )
        on_tool_result(
          tool_call_id = tool_id,
          result = paste("Synthetic agent", index, "complete"),
          is_error = FALSE
        )
      }
      on_tool_call(
        tool_call_id = "synthetic-checklist",
        tool_name = "TodoWrite",
        args = list(todos = list(
          list(id = "synthetic-complete", content = "Synthetic completed item",
               status = " Completed "),
          list(id = "synthetic-active", content = "Synthetic active item",
               activeForm = "Synthetic activity", status = "RUNNING")
        )),
        annotations = list()
      )
      on_tool_result(
        tool_call_id = "synthetic-checklist",
        result = "Synthetic checklist accepted",
        is_error = FALSE
      )
    }

    lines <- paste0(
      "SYNTHETIC_TURN_", turn, "_LINE_", sprintf("%03d", 1:120),
      " — installed browser verification content"
    )
    on_chunk(paste(
      paste0("SYNTHETIC_TURN_", turn, "_SUMMARY"),
      paste(lines, collapse = "\n\n"),
      sep = "\n\n"
    ))

    promises::promise(function(resolve, reject) {
      active$resolve <- resolve
    })
  }

  assistantUIServer("chat", handler = handler, persistence = "none")
  output$fixture_ready <- renderText(fixture_ready())

  observeEvent(input$fake_chunk, {
    req(is.function(active$on_chunk))
    next_chunk <- active$chunk + 1L
    active$chunk <- next_chunk
    fixture_ready(paste(active$turn, next_chunk, sep = ":"))
    active$on_chunk(paste0(
      "\n\nSYNTHETIC_LIVE_CHUNK_", active$turn, "_", next_chunk,
      " — ", paste(rep("stream growth", 12), collapse = " ")
    ))
  }, ignoreInit = TRUE)

  observeEvent(input$fake_done, {
    req(is.function(active$on_done))
    done <- active$on_done
    resolve <- active$resolve
    active$on_chunk <- NULL
    active$on_done <- NULL
    active$resolve <- NULL
    done()
    if (is.function(resolve)) {
      session$onFlushed(function() resolve(NULL), once = TRUE)
    }
  }, ignoreInit = TRUE)
}

shinyApp(ui, server)
