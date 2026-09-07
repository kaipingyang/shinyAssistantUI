suppressPackageStartupMessages(library(shiny))

home_library <- Sys.getenv(
  "AUI_HOME_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
suppressPackageStartupMessages(
  library(shinyAssistantUI, lib.loc = home_library)
)

`%||%` <- function(x, y) if (is.null(x)) y else x
installed_path <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
installed_version <- as.character(packageVersion("shinyAssistantUI"))

make_handler <- function(prefix) {
  run_count <- 0L
  function(message, on_chunk, on_done, attachments = list(), is_reload = FALSE, ...) {
    run_count <<- run_count + 1L
    attachment <- if (length(attachments)) attachments[[1L]] else list()
    attachment_name <- as.character(
      attachment$name %||% attachment$fileName %||% attachment$filename %||% "none"
    )[[1L]]
    attachment_data <- attachment$data %||% attachment$content %||% ""
    attachment_data <- if (length(attachment_data)) as.character(attachment_data)[[1L]] else ""
    attachment_sum <- if (nzchar(attachment_data)) {
      sum(utf8ToInt(attachment_data)) %% 1000003L
    } else {
      0L
    }
    on_chunk(sprintf(
      paste0(
        "%sRUN=%d RELOAD=%s ATT_NAME=%s ATT_LEN=%d ATT_SUM=%d\n\n",
        "MESSAGE_START\n\n%s\n\nMESSAGE_END\n\n",
        "Inline \\(x^2\\).\n\n\\[y^2\\]\n\nprices $5 through $10."
      ),
      prefix,
      run_count,
      if (isTRUE(is_reload)) "TRUE" else "FALSE",
      attachment_name,
      nchar(attachment_data, type = "bytes"),
      attachment_sum,
      message
    ))
    on_done()
  }
}

ui <- assistantUIPage(
  tags$div(
    id = "package-meta",
    `data-package-path` = installed_path,
    `data-package-version` = installed_version
  ),
  tags$pre(id = "feedback-log", textOutput("feedback_log", inline = TRUE)),
  tags$section(
    id = "enabled-fixture",
    tags$h3("Feedback enabled"),
    assistantUIOutput("chat_on", height = "520px")
  ),
  tags$section(
    id = "disabled-fixture",
    tags$h3("Feedback disabled"),
    assistantUIOutput("chat_off", height = "520px")
  ),
  title = "P1 correctness verification"
)

server <- function(input, output, session) {
  feedback_events <- reactiveVal(character())
  output$feedback_log <- renderText(paste(feedback_events(), collapse = "|"))
  outputOptions(output, "feedback_log", suspendWhenHidden = FALSE)

  assistantUIServer(
    "chat_on",
    handler = make_handler("ON_"),
    on_feedback = function(message_id, type) {
      feedback_events(c(feedback_events(), as.character(type)[[1L]]))
    },
    latex = TRUE,
    persistence = "none"
  )

  assistantUIServer(
    "chat_off",
    handler = make_handler("OFF_"),
    on_feedback = NULL,
    latex = TRUE,
    persistence = "none"
  )
}

shinyApp(ui, server)
