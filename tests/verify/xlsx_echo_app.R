# Fixture for Plan 56 Excel verify. Echo handler runs the real .attachment_text_sections
# (which does the readxl→markdown extraction) on the attachments and echoes it — no LLM,
# so the reply deterministically reveals the extracted table.
suppressMessages({library(shiny); library(shinyAssistantUI)})
ui <- assistantUIPage(assistantUIOutput("chat", height = "100%"), title = "xlsx-echo")
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, attachments = list(), ...) {
      sections <- tryCatch(
        shinyAssistantUI:::.attachment_text_sections(attachments),
        error = function(e) paste0("ERR:", conditionMessage(e))
      )
      on_chunk(paste0("GOT[", sections, "||", message, "]"))
      on_done()
    }
  )
}
shinyApp(ui, server)
