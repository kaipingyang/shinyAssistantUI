suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(promises)
  library(later)
})

continuation_prompt <- paste0(
  "Please continue from the completed tool results and provide the final response. ",
  "Do not repeat completed tool calls."
)
continuation_notice <- paste0(
  "Claude completed the tool call but did not produce a final response. ",
  "Continuing automatically\u2026"
)
state <- new.env(parent = emptyenv())
state$fail_next_continuation <- FALSE
long_markdown <- paste(
  c("# Browser verification report", sprintf(
    "## Section %03d\n\nMarkdown paragraph %03d with enough text to overflow the preview.",
    1:120, 1:120
  )),
  collapse = "\n\n"
)

handler <- function(message, on_chunk, on_done, on_error, on_auto_continue,
                    on_tool_call, on_tool_result, ...) {
  if (identical(message, continuation_prompt)) {
    if (isTRUE(state$fail_next_continuation)) {
      state$fail_next_continuation <- FALSE
      on_error("Simulated continuation stopped without another automatic retry.")
    } else {
      on_chunk("FINAL RESPONSE AFTER AUTOMATIC CONTINUATION")
      on_done()
    }
    return(invisible(NULL))
  }

  if (identical(message, "FAIL_CAP")) {
    state$fail_next_continuation <- TRUE
    on_auto_continue(notice = continuation_notice, prompt = continuation_prompt)
    on_done()
    return(invisible(NULL))
  }

  on_tool_call(
    "write-md-browser", "Write",
    list(file_path = "report.md", content = long_markdown)
  )
  on_tool_result("write-md-browser", "File written", FALSE)
  promises::promise(function(resolve, reject) {
    later::later(function() {
      on_auto_continue(notice = continuation_notice, prompt = continuation_prompt)
      on_done()
      resolve(NULL)
    }, delay = 4)
  })
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "Plan 88 browser verification"
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, persistence = "none")
}
shinyApp(ui, server)
