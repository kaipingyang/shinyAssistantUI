suppressPackageStartupMessages({ library(shiny); library(shinyAssistantUI) })

button_components <- function(label) list(list(
  id = "root", component = "Button", text = label,
  action = list(event = list(name = "confirm", context = list(source = "fixture")))
))

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "88vh"),
  div(style = "display:none", textOutput("actions"))
)

server <- function(input, output, session) {
  actions <- reactiveVal(0L)
  output$actions <- renderText(as.character(actions()))
  outputOptions(output, "actions", suspendWhenHidden = FALSE)

  handler <- function(message, on_a2ui, on_done, ...) {
    on_a2ui(list(
      list(version = "v0.9", createSurface = list(surfaceId = "fixture-surface")),
      list(version = "v0.9", updateComponents = list(
        surfaceId = "fixture-surface", components = button_components("Confirm A2UI")
      ))
    ), event_id = "fixture-event-1")
    on_done()
  }

  action_handler <- function(name, thread_id, on_a2ui, ...) {
    count <- isolate(actions()) + 1L
    actions(count)
    if (count == 1L) {
      on_a2ui(list(list(version = "v0.9", updateComponents = list(
        surfaceId = "fixture-surface", components = button_components("Updated A2UI")
      ))), event_id = "fixture-event-2")
    } else {
      on_a2ui(list(list(version = "v0.9", deleteSurface = list(
        surfaceId = "fixture-surface"
      ))), event_id = "fixture-event-3")
    }
  }

  assistantUIServer(
    "chat", handler = handler, persistence = "server",
    a2ui_action_handler = action_handler
  )
}

shinyApp(ui, server)
