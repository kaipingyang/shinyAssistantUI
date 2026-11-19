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

.invalid_form <- function(message) {
  list(content = list(list(type = "text", text = paste0("[AskUserForm] ", message))), isError = TRUE)
}

# Form definitions are trusted configuration: only files under the project's or the
# user's .claude directory (where skills live) are read.
.form_roots <- function() {
  project <- Sys.getenv("CLAUDE_PROJECT_DIR", "")
  roots <- c(if (nzchar(project)) file.path(project, ".claude"), file.path(getwd(), ".claude"),
             file.path(path.expand("~"), ".claude"))
  roots <- roots[dir.exists(roots)]
  unique(normalizePath(roots, mustWork = FALSE))
}

# Read a form definition (title, fields, submit_label) from a JSON file. Returns the
# definition, or a character error message.
.read_form_file <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    return("`form_file` must be a file path.")
  }
  if (!(startsWith(path, "/") || startsWith(path, "~/"))) {
    return("`form_file` must be an absolute path (starting with / or ~/).")
  }
  path <- path.expand(path)
  if (!grepl("\\.json$", path, ignore.case = TRUE)) return("`form_file` must be a .json file.")
  info <- file.info(path, extra_cols = FALSE)
  if (is.na(info$isdir) || isTRUE(info$isdir)) return(sprintf("`form_file` not found: %s", path))
  real <- normalizePath(path, mustWork = TRUE)
  inside <- vapply(.form_roots(), function(root) startsWith(real, paste0(root, "/")), TRUE)
  if (!any(inside)) {
    return(sprintf("`form_file` must be inside the project's or your ~/.claude directory: %s", path))
  }
  if (!grepl("\\.json$", real, ignore.case = TRUE)) return("`form_file` must be a .json file.")
  # Empty or special files (FIFOs, devices report size 0) are not form definitions.
  if (is.na(info$size) || info$size <= 0) return(sprintf("`form_file` is empty: %s", path))
  if (info$size > 64 * 1024) return("`form_file` must be at most 64 KB.")
  text <- .read_bounded(real)
  if (is.null(text)) return(sprintf("`form_file` could not be read: %s", path))
  if (nchar(text, type = "bytes") > 64 * 1024) return("`form_file` must be at most 64 KB.")
  # The checks above and the read are separate steps; refuse if the path now resolves
  # elsewhere. (A trusted-root rule, not a sandbox: the CLI's own Read tool and
  # permissions still govern what the model can read.)
  if (!identical(tryCatch(normalizePath(path, mustWork = TRUE), error = function(e) ""), real)) {
    return(sprintf("`form_file` changed while it was being read: %s", path))
  }
  def <- tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.list(def) || is.null(names(def))) return(sprintf("`form_file` is not valid JSON: %s", path))
  fields <- def$fields
  is_object <- function(x) is.list(x) && !is.null(names(x))
  if (!is.list(fields) || !is.null(names(fields)) || !length(fields) ||
      !all(vapply(fields, is_object, TRUE))) {
    return(sprintf("`form_file` must contain a non-empty `fields` array of objects: %s", path))
  }
  for (key in c("title", "submit_label")) {
    if (!is.null(def[[key]]) && !(is.character(def[[key]]) && length(def[[key]]) == 1L)) {
      return(sprintf("`form_file`: `%s` must be a string.", key))
    }
  }
  def
}

# Read at most 64 KB + 1 bytes in a child process with a short timeout, so a path that
# turns into a FIFO or a slow device cannot block this MCP server. Without a bounded
# reader the file is refused rather than read in-process.
.read_bounded <- function(path, limit = 64 * 1024 + 1, timeout = 2, head = Sys.which("head")) {
  if (!requireNamespace("processx", quietly = TRUE) || !nzchar(head)) return(NULL)
  res <- tryCatch(processx::run(head, c("-c", format(limit, scientific = FALSE), "--", path),
                                timeout = timeout, error_on_status = FALSE),
                  error = function(e) NULL)
  if (is.null(res) || !identical(res$status, 0L) || isTRUE(res$timeout)) return(NULL)
  text <- res$stdout
  Encoding(text) <- "UTF-8"
  text
}

.default_text <- function(value) {
  if (is.logical(value)) return(if (isTRUE(value)) "true" else "false")
  if (is.numeric(value)) return(format(value, scientific = FALSE, digits = 15, trim = TRUE))
  as.character(value)
}

# Fill field defaults by name. Returns the fields, or a character error message.
# null leaves the field's own default unchanged; arrays are only for multiselect.
.apply_form_defaults <- function(fields, defaults) {
  if (is.null(defaults)) return(fields)
  if (is.list(defaults) && !length(defaults) && !is.null(names(defaults))) {
    return(fields)   # {} : no defaults ([] has no names and is rejected below)
  }
  if (!is.list(defaults) || is.null(names(defaults)) || any(!nzchar(names(defaults)))) {
    return("`defaults` must be an object mapping field names to values.")
  }
  if (!is.list(fields) || !all(vapply(fields, function(f) is.list(f) && !is.null(names(f)), TRUE))) {
    return("`fields` must be an array of objects.")
  }
  names_ <- vapply(fields, function(f) {
    n <- f$name
    if (is.character(n) && length(n) == 1L && !is.na(n)) n else ""
  }, "")
  unknown <- setdiff(names(defaults), names_)
  if (length(unknown)) {
    return(sprintf("`defaults` names fields that the form does not have: %s (fields: %s).",
                   paste(unknown, collapse = ", "), paste(names_[nzchar(names_)], collapse = ", ")))
  }
  scalar <- function(x) (is.character(x) || is.numeric(x) || is.logical(x)) && length(x) == 1L && !is.na(x)
  for (key in names(defaults)) {
    value <- defaults[[key]]
    if (is.null(value)) next
    i <- match(key, names_)
    is_multi <- identical(fields[[i]]$type, "multiselect")
    if (is.list(value)) {
      if (!is_multi || !is.null(names(value)) || !all(vapply(value, scalar, TRUE))) {
        return(sprintf("`defaults`: `%s` must be a single value%s.", key,
                       if (is_multi) " or an array of values" else ""))
      }
      text <- paste(vapply(value, .default_text, ""), collapse = ",")
    } else if (scalar(value)) {
      text <- .default_text(value)
    } else {
      return(sprintf("`defaults`: `%s` must be a single value.", key))
    }
    fields[[i]]$default <- text
  }
  fields
}

.ask_form_result <- function(args) {
  title <- args$title
  fields <- args$fields
  submit_label <- args$submit_label
  if (!is.null(args$form_file)) {
    if (!is.null(fields)) return(.invalid_form("Pass either `form_file` or `fields`, not both."))
    def <- .read_form_file(args$form_file)
    if (is.character(def)) return(.invalid_form(def))
    fields <- def$fields
    title <- title %||% def$title
    submit_label <- submit_label %||% def$submit_label
  }
  if (!is.list(fields) || !length(fields)) {
    return(.invalid_form("Provide `fields` (or a `form_file` that contains them)."))
  }
  fields <- .apply_form_defaults(fields, args$defaults)
  if (is.character(fields)) return(.invalid_form(fields))
  request_id <- paste0(format(as.numeric(Sys.time()) * 1e6, scientific = FALSE), "-",
                       paste(sample(c(letters, 0:9), 16, replace = TRUE), collapse = ""))
  reply <- tryCatch(.form_remote(form_url, list(
    type = "ask_user_form", version = 1L, request_id = request_id, thread_id = form_thread,
    title = as.character(title %||% "")[1L] %||% "",
    fields = fields,
    submit_label = as.character(submit_label %||% "Submit")[1L]
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
                                             "multiselect", "checkbox", "date", "path"),
                description = "Input type. select/multiselect need `choices`. path is checked on the server when submitted (absolute or ~/ paths)."),
    choices = list(type = "array", items = list(type = "string", maxLength = 200), maxItems = 50,
                   description = "Options for select / multiselect."),
    default = list(type = "string", maxLength = 2000, description = paste(
      "Pre-filled value as text. multiselect: comma-separated; checkbox: \"true\"/\"false\";",
      "date: YYYY-MM-DD.")),
    required = list(type = "boolean", description = "Whether the user must fill it in."),
    placeholder = list(type = "string", maxLength = 200,
                       description = "text/textarea/number: example shown in the empty input."),
    min = list(type = "number", description = "number: smallest allowed value."),
    max = list(type = "number", description = "number: largest allowed value."),
    step = list(type = "number", description = "number: value must be min + k * step."),
    pattern = list(type = "string", maxLength = 200,
                   description = "text/textarea: POSIX extended regular expression the answer must match (\\d, \\w, {n} and | work; anchor with ^ and $; no lookaround or backreferences; at most 200 characters, 19 `|`, {n} up to 50 and nested {} expanding to at most 100; answers up to 500 characters)."),
    pattern_hint = list(type = "string", maxLength = 200,
                        description = "How the expected format is described to the user, e.g. \"yyyymmdd\"."),
    section = list(type = "string", maxLength = 80, description = paste(
      "Group heading. Fields with the same section are shown together in one card,",
      "placed where the section's first field is.")),
    width = list(type = "string", enum = list("full", "half"), description = paste(
      "\"half\" puts two consecutive half fields of the same section side by side;",
      "use it for short inputs such as dates, numbers and short choices.")),
    kind = list(type = "string", enum = list("any", "file", "dir"),
                description = "path: what the path must point to (default any)."),
    must_exist = list(type = "boolean",
                      description = "path: the path must already exist (default true). If false, its parent folder must exist."),
    extensions = list(type = "array", items = list(type = "string", maxLength = 16), maxItems = 20,
                      description = "path: allowed file extensions such as [\"docx\"]."),
    allow_other = list(type = "boolean",
                       description = "select: also offer a free-text input for a value not in `choices`."),
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
    "When a skill or project provides a form definition file, pass it as `form_file` and ",
    "put known values in `defaults` instead of rewriting its fields. ",
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
      form_file = list(type = "string", maxLength = 4096, description = paste(
        "Path (/... or ~/...) of a .json form definition {title, submit_label, fields} of at most",
        "64 KB inside the project's or ~/.claude directory, e.g. shipped with a skill. Use",
        "instead of `fields`; `title`/`submit_label` given here override the file.")),
      defaults = list(type = "object",
        additionalProperties = list(type = list("string", "number", "boolean", "array", "null"),
                                    items = list(type = list("string", "number", "boolean"))),
        description = paste(
          "Pre-filled values by field name, e.g. read from existing files: a string, number or",
          "true/false; an array only for multiselect; null keeps the field's own default.",
          "Values the user submits unchanged are returned to you like any other answer.")),
      `_intent` = list(type = "string", maxLength = 500, description = "Brief description of why the form is needed.")
    ),
    required = list()
  ),
  handler = function(args) .ask_form_result(args)
)

# Tests source this script to exercise .ask_form_result without starting stdio.
if (!identical(Sys.getenv("SHINY_ASSISTANT_UI_MCP_NO_SERVE"), "1")) {
  ClaudeAgentSDK::mcp_serve_stdio(
    ClaudeAgentSDK::create_sdk_mcp_server("ui", tools = list(ask_user_form))
  )
}
