# Curl-free stdio MCP server exposing `AskUserForm` (Plan 166).
#
# Launched by the claude CLI as the external stdio server "ui". The handler asks the
# addin Background Job (CLAUDE_ADDIN_FORM_URL, nanonext REQ/REP) to show the form as
# an A2UI surface in the conversation and waits for the user's submit or cancel.
# Contract matches codeagent's AskUserForm: {"submitted": true|false, "values": {...}}.
suppressPackageStartupMessages(library(ClaudeAgentSDK))
`%||%` <- function(x, y) if (is.null(x)) y else x

form_url <- Sys.getenv("CLAUDE_ADDIN_FORM_URL", "")
form_thread <- Sys.getenv("CLAUDE_ADDIN_THREAD_ID", "")
form_timeout <- suppressWarnings(as.numeric(Sys.getenv("CLAUDE_ADDIN_FORM_TIMEOUT_MS", "630000")))
if (!is.finite(form_timeout) || form_timeout <= 0) form_timeout <- 630000

# nanonext REQ sockets resend an unanswered request every 60 s by default. These
# requests wait for a person or for long R code, so a resend would show the form
# again or run the code twice. 0 disables resending (NNG guidance for
# non-idempotent requests).
.req_socket <- function(url) {
  sock <- nanonext::socket("req", dial = url)
  ok <- tryCatch({ nanonext::opt(sock, "req:resend-time") <- 0L; TRUE }, error = function(e) FALSE)
  if (!ok) {
    try(close(sock), silent = TRUE)
    stop("cannot disable request resend")
  }
  sock
}

.form_remote <- function(url, payload, timeout) {
  if (!nzchar(url) || !requireNamespace("nanonext", quietly = TRUE)) return(NULL)
  sock <- tryCatch(.req_socket(url), error = function(e) NULL)
  if (is.null(sock)) return(NULL)
  on.exit(try(close(sock), silent = TRUE), add = TRUE)
  aio <- tryCatch(nanonext::request(nanonext::context(sock), data = payload, timeout = timeout),
                  error = function(e) NULL)
  if (is.null(aio)) return(NULL)
  nanonext::call_aio(aio)
  if (is.list(aio$data)) aio$data else NULL
}

.json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null"))

.not_submitted <- function(reason, message = NULL) {
  note <- paste0(
    "The user did not submit the form (", reason, "). Do not proceed with the action ",
    "that needed it; ask in chat if you still need the information."
  )
  if (!is.null(message)) note <- paste(note, message)
  body <- list(submitted = FALSE, values = structure(list(), names = character()),
               reason = reason, note = note)
  list(content = list(list(type = "text", text = .json(body))))
}

.ask_form_result <- function(args) {
  request_id <- paste0(format(as.numeric(Sys.time()) * 1e6, scientific = FALSE), "-",
                       paste(sample(c(letters, 0:9), 16, replace = TRUE), collapse = ""))
  reply <- tryCatch(.form_remote(form_url, list(
    type = "ask_user_form", version = 1L, request_id = request_id, thread_id = form_thread,
    title = as.character(args$title %||% "")[1L] %||% "",
    fields = args$fields %||% list(),
    submit_label = as.character(args$submit_label %||% "Submit")[1L]
  ), form_timeout), error = function(e) NULL)
  if (!is.list(reply) || !identical(reply$request_id, request_id)) {
    return(.not_submitted("unavailable", "The form could not be shown."))
  }
  status <- reply$status
  if (identical(status, "submitted") && is.list(reply$values)) {
    values <- reply$values
    if (!length(values)) values <- structure(list(), names = character())
    return(list(content = list(list(type = "text",
                                    text = .json(list(submitted = TRUE, values = values))))))
  }
  if (identical(status, "invalid")) {
    return(list(content = list(list(type = "text", text = paste0(
      "[AskUserForm] ", reply$message %||% "Invalid form."
    ))), isError = TRUE))
  }
  .not_submitted(if (identical(status, "cancelled")) reply$reason %||% "cancelled" else "unavailable",
                 reply$message)
}

field_schema <- list(
  type = "object",
  properties = list(
    name = list(type = "string", maxLength = 64,
                description = "Machine name (letters, digits, underscore); the key in the result."),
    label = list(type = "string", maxLength = 200, description = "Label shown to the user."),
    type = list(type = "string", enum = list("text", "textarea", "number", "select",
                                             "multiselect", "checkbox", "date"),
                description = "Input type. select/multiselect need `choices`."),
    choices = list(type = "array", items = list(type = "string", maxLength = 200), maxItems = 50,
                   description = "Options for select / multiselect."),
    default = list(type = "string", maxLength = 2000, description = paste(
      "Pre-filled value as text. multiselect: comma-separated; checkbox: \"true\"/\"false\";",
      "date: YYYY-MM-DD.")),
    required = list(type = "boolean", description = "Whether the user must fill it in."),
    help = list(type = "string", maxLength = 500, description = "Short hint under the field.")
  ),
  required = list("name", "type")
)

ask_user_form <- sdk_mcp_tool(
  name = "AskUserForm",
  description = paste0(
    "Show the user a small form in the chat and wait for them to submit or cancel it. ",
    "Use AskUserQuestion for 1-2 single-choice questions with 2 to at most 4 options each; ",
    "use this form for everything else: 3 or more questions at once, any question that ",
    "needs multiple selection or more than 4 options, and any text, numbers, dates or ",
    "required fields (for example the parameters of an analysis). Pre-fill `default` with ",
    "your best guess so the user mostly confirms, and list the full set of options. ",
    "Do NOT use it for permission requests. The result is JSON: ",
    "{\"submitted\": true|false, \"values\": {name: value}}; if submitted is false the ",
    "user cancelled, so do not proceed with the action."
  ),
  input_schema = list(
    type = "object",
    properties = list(
      title = list(type = "string", maxLength = 200, description = "Short heading shown above the form."),
      fields = list(type = "array", items = field_schema, minItems = 1, maxItems = 20,
                    description = "Form fields, at most 20."),
      submit_label = list(type = "string", maxLength = 60, description = "Submit button text (default \"Submit\")."),
      `_intent` = list(type = "string", maxLength = 500, description = "Brief description of why the form is needed.")
    ),
    required = list("title", "fields")
  ),
  handler = function(args) .ask_form_result(args)
)

# Tests source this script to exercise .ask_form_result without starting stdio.
if (!identical(Sys.getenv("SHINY_ASSISTANT_UI_MCP_NO_SERVE"), "1")) {
  ClaudeAgentSDK::mcp_serve_stdio(
    ClaudeAgentSDK::create_sdk_mcp_server("ui", tools = list(ask_user_form))
  )
}
