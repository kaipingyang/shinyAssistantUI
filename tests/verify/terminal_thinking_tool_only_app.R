library(shiny)

verify_lib <- Sys.getenv(
  "SHINYASSISTANTUI_VERIFY_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
library(shinyAssistantUI, lib.loc = verify_lib)

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$meta(
    name = "shinyassistant-terminal-actions-package",
    content = paste0("installed-", as.character(packageVersion("shinyAssistantUI")))
  ),
  tags$div(
    style = "position:fixed;left:-10000px;top:-10000px",
    actionButton("fake_done", "Complete synthetic turn"),
    actionButton("fake_active_requesting", "Send active synthetic requesting"),
    actionButton("fake_late_thinking", "Send late synthetic thinking"),
    actionButton("fake_late_requesting", "Send late synthetic requesting"),
    actionButton("fake_late_wrapped_requesting", "Send late wrapped requesting"),
    actionButton("fake_regular_status", "Send synthetic regular status"),
    actionButton("fake_proactive_mid", "Publish proactive intermediate snapshot"),
    actionButton("fake_proactive_final", "Publish proactive final snapshot"),
    textOutput("fixture_state", inline = TRUE)
  ),
  assistantUIOutput("chat", height = "100%")
)

server <- function(input, output, session) {
  active <- new.env(parent = emptyenv())
  fixture_state <- reactiveVal("ready")

  handler <- function(message, on_chunk, on_done, on_error,
                      on_tool_call, on_tool_result, on_status,
                      on_proactive_messages, run_id = NULL, ...) {
    active$on_done <- on_done
    active$run_id <- run_id
    active$on_status <- on_status
    active$on_proactive_messages <- on_proactive_messages
    on_status("thinking_tokens")
    on_tool_call(
      tool_call_id = "synthetic-tool-only",
      tool_name = "Bash",
      args = list(command = "printf synthetic"),
      annotations = list()
    )
    on_tool_result(
      tool_call_id = "synthetic-tool-only",
      result = "SYNTHETIC TOOL RESULT",
      is_error = FALSE
    )
    on_chunk("SYNTHETIC FINAL ANSWER")
    fixture_state("running")

    promises::promise(function(resolve, reject) {
      active$resolve <- resolve
    })
  }

  assistantUIServer("chat", handler = handler, persistence = "none")
  output$fixture_state <- renderText(fixture_state())

  observeEvent(input$fake_done, {
    req(is.function(active$on_done))
    done <- active$on_done
    resolve <- active$resolve
    active$on_done <- NULL
    active$resolve <- NULL
    done()
    fixture_state("done")
    if (is.function(resolve)) {
      session$onFlushed(function() resolve(NULL), once = TRUE)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$fake_active_requesting, {
    req(is.function(active$on_status))
    active$on_status("requesting")
    fixture_state("active-requesting-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_late_thinking, {
    req(is.function(active$on_status))
    active$on_status("thinking_tokens")
    fixture_state("late-thinking-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_late_requesting, {
    req(is.function(active$on_status))
    active$on_status("requesting")
    fixture_state("late-requesting-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_late_wrapped_requesting, {
    req(is.function(active$on_status))
    active$on_status("status", "requesting")
    fixture_state("late-wrapped-requesting-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_regular_status, {
    req(is.function(active$on_status))
    active$on_status("working", "SYNTHETIC BACKGROUND READY")
    fixture_state("regular-status-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_proactive_mid, {
    req(is.function(active$on_proactive_messages))
    active$on_proactive_messages(
      messages = list(list(
        id = "proactive-mid", role = "assistant",
        content = list(list(type = "text", text = "SYNTHETIC PROACTIVE INTERMEDIATE"))
      )),
      revision = 101L,
      after_run_id = active$run_id
    )
    fixture_state("proactive-mid-sent")
  }, ignoreInit = TRUE)

  observeEvent(input$fake_proactive_final, {
    req(is.function(active$on_proactive_messages))
    active$on_proactive_messages(
      messages = list(
        list(
          id = "proactive-mid", role = "assistant",
          content = list(list(type = "text", text = "SYNTHETIC PROACTIVE INTERMEDIATE"))
        ),
        list(
          id = "proactive-final", role = "assistant",
          content = list(list(type = "text", text = "SYNTHETIC PROACTIVE FINAL"))
        )
      ),
      revision = 102L,
      after_run_id = active$run_id
    )
    fixture_state("proactive-final-sent")
  }, ignoreInit = TRUE)
}

shinyApp(ui, server)
