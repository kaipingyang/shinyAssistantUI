suppressPackageStartupMessages({ library(shiny); library(shinyAssistantUI) })

catalog <- "urn:shinyassistantui:a2ui:catalog:v1"

submit_component <- function(label) list(
  id = "submit", component = "Button", text = label,
  action = list(event = list(
    name = "confirm",
    context = list(
      formId = "fixture-form",
      values = list(
        name = list(path = "/form/name"),
        accepted = list(path = "/form/accepted")
      )
    )
  ))
)

initial_components <- function() list(
  list(
    id = "root", component = "Column",
    children = list("heading", "name", "mirror", "accepted", "items", "submit", "open-safe", "open-unsafe")
  ),
  list(id = "heading", component = "Text", text = list(path = "/status"), variant = "h3"),
  list(id = "name", component = "TextField", label = "Name", value = list(path = "/form/name")),
  list(id = "mirror", component = "Text", text = list(path = "/form/name")),
  list(id = "accepted", component = "CheckBox", label = "Accepted", value = list(path = "/form/accepted")),
  list(id = "items", component = "List", children = list(componentId = "item", path = "/items")),
  list(id = "item", component = "Text", text = list(path = "name")),
  submit_component("Confirm A2UI"),
  list(id = "open-safe", component = "Button", text = "Open safe URL", action = list(
    functionCall = list(call = "openUrl", args = list(url = "https://example.com/docs"))
  )),
  list(id = "open-unsafe", component = "Button", text = "Open unsafe URL", action = list(
    functionCall = list(call = "openUrl", args = list(url = "javascript:alert(1)"))
  ))
)

history_snapshot <- list(
  list(version = "v0.9", createSurface = list(surfaceId = "history-surface")),
  list(version = "v0.9", updateComponents = list(
    surfaceId = "history-surface",
    components = list(list(id = "root", component = "Text", text = "Historical A2UI from snapshot"))
  ))
)
history_marker <- function(message_id) list(
  kind = "surface", schemaVersion = 1L, transportVersion = 1L,
  protocolVersion = "v0.9", surfaceId = "history-surface",
  epoch = 1, revision = 1, lastSequence = 1,
  recentEventIds = list(), snapshot = history_snapshot,
  snapshotDigest = shinyAssistantUI:::.a2ui_digest(history_snapshot),
  anchor = list(runId = "history-run", messageId = message_id)
)
legacy_history_message <- list(
  id = "history-a2ui-legacy", role = "assistant",
  content = list(list(
    type = "generative-ui",
    spec = list(`$type` = "Markdown", value = "POISONED LEGACY DERIVED SPEC"),
    a2ui = history_marker("history-a2ui-legacy")
  )),
  createdAt = "2026-10-04T00:00:00Z"
)
present_history_message <- list(
  id = "history-a2ui-present", role = "assistant",
  content = list(list(
    type = "tool-call", toolCallId = "a2ui:history-surface", toolName = "present",
    args = list(`$type` = "Markdown", value = "POISONED PRESENT DERIVED SPEC"),
    argsText = "{}", result = list(),
    artifact = list(
      a2ui = history_snapshot,
      shinyA2ui = history_marker("history-a2ui-present")
    )
  )),
  createdAt = "2026-10-04T00:00:01Z"
)
history_checkpoint <- list(
  transportVersion = 1L, protocolVersion = "v0.9", schemaVersion = 1L,
  lastAcceptedSequence = 1, generation = 1, eventLedger = list(),
  lineage = list(list(surfaceId = "history-surface", epoch = 1, revision = 1))
)

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "88vh"),
  div(
    style = "display:none",
    textOutput("actions"),
    textOutput("action_context"),
    textOutput("validation_error")
  )
)

server <- function(input, output, session) {
  actions <- reactiveVal(0L)
  action_context <- reactiveVal("")
  validation_error <- reactiveVal("")
  output$actions <- renderText(as.character(actions()))
  output$action_context <- renderText(action_context())
  output$validation_error <- renderText(validation_error())
  outputOptions(output, "actions", suspendWhenHidden = FALSE)
  outputOptions(output, "action_context", suspendWhenHidden = FALSE)
  outputOptions(output, "validation_error", suspendWhenHidden = FALSE)

  handler <- function(message, on_a2ui, on_done, ...) {
    on_a2ui(list(
      list(version = "v0.9.1", createSurface = list(
        surfaceId = "fixture-surface", catalogId = catalog, sendDataModel = FALSE
      )),
      list(version = "v0.9.1", updateComponents = list(
        surfaceId = "fixture-surface", components = initial_components()
      )),
      list(version = "v0.9.1", updateDataModel = list(
        surfaceId = "fixture-surface", path = "/", value = list(
          status = "Ready A2UI",
          form = list(name = "Ada", accepted = FALSE),
          items = list(list(name = "First item"), list(name = "Second item"))
        )
      ))
    ), event_id = "fixture-event-1")
    on_done()
  }

  api <- NULL
  feedback_recovered <- reactiveVal(FALSE)
  action_handler <- function(name, context, thread_id, on_a2ui, ...) {
    count <- isolate(actions()) + 1L
    actions(count)
    action_context(as.character(jsonlite::toJSON(context, auto_unbox = TRUE, null = "null")))
    if (count == 1L) {
      session$sendCustomMessage("chat_input:a2ui", list(
        transportVersion = 1L, threadId = thread_id, runId = "invalid-run",
        eventId = "invalid-event", sequence = 2,
        operations = list(list(
          version = "v0.9.1",
          updateComponents = list(
            surfaceId = "fixture-surface",
            components = list(list(id = "root", component = "Script"))
          )
        ))
      ))
    } else {
      on_a2ui(list(list(version = "v0.9.1", deleteSurface = list(
        surfaceId = "fixture-surface"
      ))), event_id = "fixture-event-3")

    }
  }

  error_handler <- function(code, thread_id, surface_id, path, message, ...) {
    before_sequence <- api$a2ui_checkpoint(thread_id)$lastAcceptedSequence
    validation_error(as.character(jsonlite::toJSON(list(
      code = code, threadId = thread_id, surfaceId = surface_id,
      path = path, message = message, beforeSequence = before_sequence
    ), auto_unbox = TRUE)))
    if (!isolate(feedback_recovered())) {
      feedback_recovered(TRUE)
      api$send_a2ui(list(
        list(version = "v0.9.1", updateComponents = list(
          surfaceId = "fixture-surface", components = list(submit_component("Updated A2UI"))
        )),
        list(version = "v0.9.1", updateDataModel = list(
          surfaceId = "fixture-surface", path = "/status", value = "Server updated"
        ))
      ), thread_id = thread_id, run_id = "feedback-recovery", event_id = "fixture-event-2")
    }
  }

  api <- assistantUIServer(
    "chat", handler = handler, persistence = "server", show_thread_list = TRUE,
    a2ui_action_handler = action_handler,
    a2ui_error_handler = error_handler,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      if (identical(session_id, "history-a2ui-legacy")) {
        send_thread(list(legacy_history_message), a2ui_checkpoint = history_checkpoint)
      } else if (identical(session_id, "history-a2ui-present")) {
        send_thread(list(present_history_message), a2ui_checkpoint = history_checkpoint)
      } else {
        send_thread(list())
      }
    }
  )
  session$onFlushed(function() {
    api$send_sessions(list(sessions = list(
      list(id = "history-a2ui-legacy", title = "A2UI Legacy History"),
      list(id = "history-a2ui-present", title = "A2UI Present History")
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
