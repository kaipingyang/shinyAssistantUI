# Plan 166 — AskUserForm rendered as a server-authoritative A2UI surface.
#
# Claude calls the MCP tool `mcp__ui__AskUserForm` (inst/mcp/ask_form_server.R). The
# subprocess asks this Background Job over nanonext; the form service validates the
# field spec (same contract as codeagent's AskUserForm), emits an A2UI surface into the
# thread through the active run's `on_a2ui`, and resolves when the user's submit/cancel
# A2UI action arrives. Every failure path resolves as cancelled, never as submitted.

.ASK_FORM_FIELD_TYPES <- c("text", "textarea", "number", "select", "multiselect",
                           "checkbox", "date")
.ASK_FORM_MAX_FIELDS <- 20L
# Submitted text stays below the A2UI authority's 16 KiB-per-string limit.
.ASK_FORM_MAX_TEXT <- 4000L
.ASK_FORM_MAX_REQUEST_BYTES <- 64L * 1024L
.ASK_FORM_MAX_LIVE <- 12L
.ASK_FORM_TOOL <- "mcp__ui__AskUserForm"
.ASK_FORM_REQUEST_KEYS <- c("type", "version", "request_id", "thread_id", "title",
                            "fields", "submit_label")

.ask_form_scalar <- function(x, default) {
  x <- unlist(x, use.names = FALSE)
  if (!length(x) || is.na(x[1L])) return(default)
  x[1L]
}

.ask_form_string <- function(value) {
  is.character(value) && length(value) == 1L && !is.na(value)
}

# Normalise model-supplied fields (codeagent .form_validate_fields contract) or
# return a character message the model can act on. PURE.
.ask_form_validate_fields <- function(fields) {
  if (is.data.frame(fields)) fields <- split(fields, seq_len(nrow(fields)))
  if (!is.list(fields) || !length(fields)) {
    return("`fields` must be a non-empty list of field objects.")
  }
  if (length(fields) > .ASK_FORM_MAX_FIELDS) {
    return(sprintf("A form can have at most %d fields.", .ASK_FORM_MAX_FIELDS))
  }
  out <- vector("list", length(fields))
  for (i in seq_along(fields)) {
    f <- as.list(fields[[i]])
    name <- as.character(.ask_form_scalar(f$name, ""))
    if (is.na(name) || !grepl("^[A-Za-z][A-Za-z0-9_]{0,63}$", name)) {
      return(sprintf("Field %d: `name` must start with a letter and use letters, digits or underscores.", i))
    }
    type <- as.character(.ask_form_scalar(f$type, "text"))
    if (!type %in% .ASK_FORM_FIELD_TYPES) {
      return(sprintf("Field `%s`: unknown type \"%s\" (use one of %s).", name, type,
                     paste(.ASK_FORM_FIELD_TYPES, collapse = ", ")))
    }
    choices <- as.character(unlist(f$choices %||% character(0), use.names = FALSE))
    choices <- unique(choices[!is.na(choices) & nzchar(choices)])
    if (any(nchar(choices) > 200L)) return(sprintf("Field `%s`: each choice must be at most 200 characters.", name))
    if (type %in% c("select", "multiselect") && !length(choices)) {
      return(sprintf("Field `%s`: type \"%s\" needs `choices`.", name, type))
    }
    if (length(choices) > 50L) return(sprintf("Field `%s`: at most 50 choices.", name))
    default <- unlist(f$default, use.names = FALSE)
    default <- default[!is.na(default)]
    default <- if (!length(default)) "" else paste(as.character(default), collapse = ",")
    if (nchar(default) > 2000L) return(sprintf("Field `%s`: `default` must be at most 2000 characters.", name))
    out[[i]] <- list(
      name = name,
      label = substr(as.character(.ask_form_scalar(f$label, name)), 1L, 200L),
      type = type,
      choices = choices,
      default = default,
      required = isTRUE(as.logical(.ask_form_scalar(f$required, FALSE))),
      help = substr(as.character(.ask_form_scalar(f$help, "")), 1L, 500L)
    )
  }
  names_ <- vapply(out, `[[`, character(1L), "name")
  if (anyDuplicated(names_)) {
    return(sprintf("Field names must be unique (repeated: %s).",
                   paste(unique(names_[duplicated(names_)]), collapse = ", ")))
  }
  out
}

.ask_form_split_default <- function(value) {
  if (!nzchar(value)) return(character())
  parts <- trimws(strsplit(value, ",", fixed = TRUE)[[1L]])
  parts[nzchar(parts)]
}

# Initial data-model value for one field. PURE.
.ask_form_initial <- function(field) {
  switch(field$type,
    checkbox = isTRUE(as.logical(field$default)),
    multiselect = as.list(intersect(.ask_form_split_default(field$default), field$choices)),
    select = if (field$default %in% field$choices) field$default else "",
    date = if (grepl("^\\d{4}-\\d{2}-\\d{2}$", field$default)) field$default else "",
    field$default
  )
}

# A2UI v0.9.1 operations creating the form surface. PURE.
.ask_form_surface_ops <- function(form_id, title, spec, submit_label = "Submit") {
  label_of <- function(field) if (isTRUE(field$required)) paste0(field$label, " *") else field$label
  path_of <- function(field) paste0("/values/", field$name)
  field_ids <- character()
  components <- list(list(id = "title", component = "Text", text = title, variant = "h3"))
  for (field in spec) {
    id <- paste0("field-", field$name)
    binding <- list(path = path_of(field))
    component <- switch(field$type,
      text = list(id = id, component = "TextField", label = label_of(field), value = binding),
      textarea = list(id = id, component = "TextField", label = label_of(field), value = binding,
                      variant = "longText"),
      number = list(id = id, component = "TextField", label = label_of(field), value = binding,
                    variant = "number"),
      select = list(id = id, component = "ChoicePicker", label = label_of(field), value = binding,
                    variant = "mutuallyExclusive",
                    options = lapply(field$choices, function(choice) list(label = choice, value = choice))),
      multiselect = list(id = id, component = "ChoicePicker", label = label_of(field), value = binding,
                         variant = "multipleSelection",
                         options = lapply(field$choices, function(choice) list(label = choice, value = choice))),
      checkbox = list(id = id, component = "CheckBox", label = label_of(field), value = binding),
      date = list(id = id, component = "DateTimeInput", label = label_of(field), value = binding,
                  enableDate = TRUE, enableTime = FALSE)
    )
    # The renderer exposes TextField/ChoicePicker/DateTimeInput labels only as
    # aria-label, so show the label visibly too (CheckBox renders its own). The
    # A2UI Text vocabulary renders plain text, so labels stay literal.
    if (!identical(field$type, "checkbox")) {
      label_id <- paste0("label-", field$name)
      components <- c(components, list(list(
        id = label_id, component = "Text", text = label_of(field)
      )))
      field_ids <- c(field_ids, label_id)
    }
    components <- c(components, list(component))
    field_ids <- c(field_ids, id)
    if (nzchar(field$help)) {
      help_id <- paste0("help-", field$name)
      components <- c(components, list(list(id = help_id, component = "Text",
                                            text = field$help, variant = "caption")))
      field_ids <- c(field_ids, help_id)
    }
  }
  value_bindings <- stats::setNames(
    lapply(spec, function(field) list(path = path_of(field))),
    vapply(spec, `[[`, "", "name")
  )
  components <- c(components, list(
    list(id = "error", component = "Text", text = list(path = "/error")),
    list(id = "submit", component = "Button", text = submit_label,
         action = list(event = list(name = "ask_form.submit",
                                    context = list(formId = form_id, values = value_bindings)))),
    list(id = "cancel", component = "Button", text = "Cancel",
         action = list(event = list(name = "ask_form.cancel", context = list(formId = form_id)))),
    list(id = "actions", component = "Row", children = list("submit", "cancel"))
  ))
  root <- list(id = "root", component = "Column",
               children = as.list(c("title", field_ids, "error", "actions")))
  values <- stats::setNames(lapply(spec, .ask_form_initial), vapply(spec, `[[`, "", "name"))
  list(
    list(version = "v0.9.1", createSurface = list(
      surfaceId = form_id, catalogId = "urn:shinyassistantui:a2ui:catalog:v1",
      sendDataModel = FALSE
    )),
    list(version = "v0.9.1", updateComponents = list(
      surfaceId = form_id, components = c(list(root), components)
    )),
    list(version = "v0.9.1", updateDataModel = list(
      surfaceId = form_id, path = "/", value = list(values = values, error = "")
    ))
  )
}

# Coerce and validate submitted values. Returns list(values=, problems=). PURE.
.ask_form_collect <- function(spec, raw) {
  raw <- if (is.list(raw)) raw else list()
  values <- list()
  problems <- character()
  text_of <- function(x) {
    x <- unlist(x, use.names = FALSE)
    if (!length(x) || is.na(x[1L])) "" else as.character(x[1L])
  }
  for (field in spec) {
    value <- raw[[field$name]]
    result <- switch(field$type,
      number = {
        text <- trimws(text_of(value))
        number <- suppressWarnings(as.numeric(text))
        if (!nzchar(text)) NULL
        else if (length(number) != 1L || !is.finite(number)) {
          problems <- c(problems, sprintf("%s must be a number.", field$label)); NULL
        } else number
      },
      checkbox = isTRUE(as.logical(unlist(value)[1L] %||% FALSE)),
      multiselect = {
        picks <- as.character(unlist(value %||% character(), use.names = FALSE))
        picks <- unique(picks[!is.na(picks) & nzchar(picks)])
        if (length(setdiff(picks, field$choices))) {
          problems <- c(problems, sprintf("%s has an unknown choice.", field$label))
        }
        intersect(picks, field$choices)
      },
      select = {
        pick <- text_of(value)
        if (nzchar(pick) && !pick %in% field$choices) {
          problems <- c(problems, sprintf("%s has an unknown choice.", field$label)); ""
        } else pick
      },
      date = {
        text <- trimws(text_of(value))
        if (!nzchar(text)) NULL
        else if (!grepl("^\\d{4}-\\d{2}-\\d{2}$", text) || is.na(as.Date(text, optional = TRUE))) {
          problems <- c(problems, sprintf("%s must be a date (YYYY-MM-DD).", field$label)); NULL
        } else text
      },
      {
        text <- text_of(value)
        if (nchar(text) > .ASK_FORM_MAX_TEXT) {
          problems <- c(problems, sprintf("%s is too long.", field$label))
          substr(text, 1L, .ASK_FORM_MAX_TEXT)
        } else text
      }
    )
    empty <- !identical(field$type, "checkbox") &&
      (is.null(result) || !length(result) || (is.character(result) && !any(nzchar(result))))
    if (isTRUE(field$required) && empty) {
      problems <- c(problems, sprintf("Please fill in %s.", field$label))
    }
    values[field$name] <- list(result)
  }
  list(values = values, problems = unique(problems))
}

# Read-only summary replacing the inputs once the form is settled. PURE.
.ask_form_summary_ops <- function(form_id, title, spec, status, values = NULL) {
  lines <- list(list(id = "status", component = "Text", text = status, variant = "caption"))
  ids <- "status"
  if (is.list(values)) {
    for (field in spec) {
      value <- values[[field$name]]
      shown <- if (is.null(value) || !length(value)) "" else paste(value, collapse = ", ")
      if (nchar(shown) > 500L) shown <- paste0(substr(shown, 1L, 500L), "\u2026")
      if (identical(field$type, "checkbox")) shown <- if (isTRUE(value)) "Yes" else "No"
      id <- paste0("summary-", field$name)
      lines <- c(lines, list(list(id = id, component = "Text",
                                  text = paste0(field$label, ": ", shown))))
      ids <- c(ids, id)
    }
  }
  root <- list(id = "root", component = "Column", children = as.list(c("title", ids)))
  list(list(version = "v0.9.1", updateComponents = list(
    surfaceId = form_id, components = c(list(root), lines)
  )))
}

# Active-run A2UI emitters, keyed by thread. A registration is released only by
# the token returned from that registration.
.new_ask_form_emitters <- function() {
  entries <- new.env(parent = emptyenv())
  listeners <- list()
  serial <- 0L
  noop <- function() invisible(FALSE)
  list(
    # The first active run of a thread owns it; another session (or an overlapping
    # run) cannot take over the thread's forms. Release notifies listeners so the
    # run's pending forms are cancelled when it ends.
    register = function(thread_id, run_id, emit, owner = NULL) {
      if (!.ask_form_string(thread_id) || !is.function(emit)) return(noop)
      if (!is.null(get0(thread_id, envir = entries, inherits = FALSE))) return(noop)
      serial <<- serial + 1L
      token <- serial
      entry <- list(run_id = run_id, emit = emit, owner = owner, token = token)
      assign(thread_id, entry, envir = entries)
      function() {
        current <- get0(thread_id, envir = entries, inherits = FALSE)
        if (is.null(current) || !identical(current$token, token)) return(invisible(FALSE))
        rm(list = thread_id, envir = entries)
        for (listener in listeners) tryCatch(listener(entry), error = function(e) NULL)
        invisible(TRUE)
      }
    },
    on_release = function(listener) {
      listeners[[length(listeners) + 1L]] <<- listener
      invisible(TRUE)
    },
    get = function(thread_id) {
      if (!.ask_form_string(thread_id)) return(NULL)
      get0(thread_id, envir = entries, inherits = FALSE)
    }
  )
}

.valid_ask_form_request <- function(req) {
  is.list(req) && length(names(req)) == length(.ASK_FORM_REQUEST_KEYS) &&
    setequal(names(req), .ASK_FORM_REQUEST_KEYS) &&
    identical(req$type, "ask_user_form") &&
    is.numeric(req$version) && length(req$version) == 1L && identical(as.numeric(req$version), 1) &&
    .ask_form_string(req$request_id) && nzchar(req$request_id) &&
    .ask_form_string(req$thread_id) && nzchar(req$thread_id) &&
    .ask_form_string(req$title) && .ask_form_string(req$submit_label)
}

.new_ask_form_service <- function(
    emitters,
    timeout = 600,
    schedule = function(callback, delay) {
      timer <- later::later(callback, delay = delay)
      function() .cancel_later_timer(timer)
    },
    id_factory = function() substr(.diagnostics_hex_token(), 1L, 24L)) {
  pending <- new.env(parent = emptyenv())
  finished <- new.env(parent = emptyenv())  # thread -> settled surface ids (oldest first)
  safe <- function(fn, ...) tryCatch(fn(...), error = function(e) NULL)
  status_text <- c(
    user = "Cancelled.", stopped = "Stopped before the form was submitted.",
    timeout = "Expired before the form was submitted.",
    disconnected = "Closed because the browser disconnected.",
    ended = "Closed because the conversation turn ended.",
    shutdown = "Closed because the session ended."
  )

  remember_finished <- function(thread_id, form_id) {
    ids <- c(get0(thread_id, envir = finished, inherits = FALSE) %||% character(), form_id)
    assign(thread_id, ids, envir = finished)
  }
  # Keep the thread under the A2UI live-surface limit by deleting the oldest
  # settled forms before a new one is created.
  pending_count <- function(thread_id) sum(vapply(ls(pending), function(key) {
    identical(get(key, envir = pending)$thread_id, thread_id)
  }, logical(1)))
  trim_finished <- function(thread_id, emit) {
    ids <- get0(thread_id, envir = finished, inherits = FALSE) %||% character()
    extra <- length(ids) + pending_count(thread_id) + 1L - .ASK_FORM_MAX_LIVE
    if (extra <= 0L || !length(ids)) return(invisible(NULL))
    drop <- utils::head(ids, extra)
    deleted <- tryCatch({
      emit(lapply(drop, function(id) list(version = "v0.9.1", deleteSurface = list(surfaceId = id))))
      TRUE
    }, error = function(e) FALSE)
    if (deleted) assign(thread_id, setdiff(ids, drop), envir = finished)
    invisible(NULL)
  }

  settle <- function(form_id, response, summary = NULL, emit = NULL) {
    entry <- get0(form_id, envir = pending, inherits = FALSE)
    if (is.null(entry)) return(FALSE)
    rm(list = form_id, envir = pending)
    safe(entry$cancel_timer)
    # Lock the UI before Claude sees the outcome; if the read-only summary cannot
    # be shown, remove the surface so it can never look editable.
    target <- emit %||% entry$emit
    shown <- is.null(summary) || isTRUE(tryCatch({ target(summary); TRUE }, error = function(e) FALSE))
    if (!shown) {
      safe(target, list(list(version = "v0.9.1", deleteSurface = list(surfaceId = form_id))))
    } else {
      remember_finished(entry$thread_id, form_id)
    }
    response$request_id <- entry$request_id
    safe(entry$respond, response)
    TRUE
  }
  cancel <- function(form_id, reason) {
    entry <- get0(form_id, envir = pending, inherits = FALSE)
    if (is.null(entry)) return(FALSE)
    settle(form_id, list(status = "cancelled", reason = reason),
           .ask_form_summary_ops(form_id, entry$title, entry$spec, status_text[[reason]]))
  }

  request <- function(req, respond) {
    request_id <- if (is.list(req) && .ask_form_string(req$request_id)) req$request_id else NULL
    reply <- function(...) safe(respond, c(list(...), list(request_id = request_id)))
    if (!.valid_ask_form_request(req)) {
      return(invisible(reply(status = "invalid", message = "Malformed AskUserForm request.")))
    }
    request_bytes <- tryCatch(nchar(as.character(jsonlite::toJSON(req, auto_unbox = TRUE, null = "null")),
                                    type = "bytes"), error = function(e) Inf)
    if (!is.finite(request_bytes) || request_bytes > .ASK_FORM_MAX_REQUEST_BYTES) {
      return(invisible(reply(status = "invalid",
                             message = "The form is too large; use fewer or shorter fields.")))
    }
    spec <- .ask_form_validate_fields(req$fields)
    if (is.character(spec)) return(invisible(reply(status = "invalid", message = spec)))
    title <- substr(req$title, 1L, 200L)
    submit_label <- substr(if (nzchar(req$submit_label)) req$submit_label else "Submit", 1L, 60L)
    emitter <- emitters$get(req$thread_id)
    if (is.null(emitter)) {
      return(invisible(reply(status = "unavailable",
                             message = "No active conversation turn can show the form.")))
    }
    if (pending_count(req$thread_id) >= .ASK_FORM_MAX_LIVE) {
      return(invisible(reply(status = "unavailable",
                             message = "Too many forms are already open in this conversation.")))
    }
    form_id <- paste0("ask-form-", id_factory())
    trim_finished(req$thread_id, emitter$emit)
    shown <- tryCatch({
      emitter$emit(.ask_form_surface_ops(form_id, title, spec, submit_label))
      TRUE
    }, error = function(e) conditionMessage(e))
    if (!isTRUE(shown)) {
      return(invisible(reply(status = "unavailable", message = paste("The form could not be shown:", shown))))
    }
    entry <- list(request_id = request_id, thread_id = req$thread_id, owner = emitter$owner,
                  token = emitter$token,
                  title = title, spec = spec, respond = respond, emit = emitter$emit,
                  cancel_timer = NULL)
    assign(form_id, entry, envir = pending)
    entry$cancel_timer <- safe(schedule, function() cancel(form_id, "timeout"), timeout)
    if (exists(form_id, envir = pending, inherits = FALSE)) assign(form_id, entry, envir = pending)
    invisible(TRUE)
  }

  handle_action <- function(name, context, thread_id, surface_id, on_error, on_a2ui = NULL,
                            owner = NULL) {
    fail <- function(reason) {
      safe(on_error, reason)
      invisible(FALSE)
    }
    if (!name %in% c("ask_form.submit", "ask_form.cancel")) return(fail("Unsupported action."))
    entry <- if (.ask_form_string(surface_id)) get0(surface_id, envir = pending, inherits = FALSE) else NULL
    if (is.null(entry) || !identical(entry$thread_id, thread_id) ||
        !identical(entry$owner, owner) ||
        !is.list(context) || !identical(context$formId, surface_id)) {
      return(fail("This form is no longer active."))
    }
    emit <- if (is.function(on_a2ui)) on_a2ui else entry$emit
    if (identical(name, "ask_form.cancel")) {
      settle(surface_id, list(status = "cancelled", reason = "user"),
             .ask_form_summary_ops(surface_id, entry$title, entry$spec, status_text[["user"]]), emit)
      return(invisible(TRUE))
    }
    collected <- .ask_form_collect(entry$spec, context$values)
    if (length(collected$problems)) {
      safe(emit, list(list(version = "v0.9.1", updateDataModel = list(
        surfaceId = surface_id, path = "/error",
        value = paste(collected$problems, collapse = " ")
      ))))
      return(invisible(TRUE))
    }
    settle(surface_id, list(status = "submitted", values = collected$values),
           .ask_form_summary_ops(surface_id, entry$title, entry$spec, "Submitted.", collected$values),
           emit)
    invisible(TRUE)
  }

  cancel_where <- function(predicate, reason) {
    ids <- Filter(function(id) isTRUE(predicate(get(id, envir = pending))), ls(pending))
    for (id in ids) cancel(id, reason)
    invisible(length(ids))
  }

  emitters$on_release(function(registration) {
    cancel_where(function(e) identical(e$token, registration$token), "ended")
  })

  list(
    request = request,
    handle_action = handle_action,
    cancel_thread = function(thread_id, owner) cancel_where(function(e) {
      identical(e$thread_id, thread_id) && identical(e$owner, owner)
    }, "stopped"),
    cancel_owner = function(owner) cancel_where(function(e) identical(e$owner, owner), "disconnected"),
    pending = function() ls(pending),
    close = function() cancel_where(function(e) TRUE, "shutdown")
  )
}

# AskUserForm is the user interaction itself, so it never needs a permission prompt.
# AskUserForm is the user interaction itself, so it needs no permission prompt.
# Only the addin call site that installed its own form server adds it (trust is
# decided where ownership is known, never inferred from a server config).
.addin_form_allowed_tools <- function(base = NULL) {
  if (.ASK_FORM_TOOL %in% base) return(base)
  c(base, .ASK_FORM_TOOL)
}

# Stdio MCP config for inst/mcp/ask_form_server.R (ClaudeAgentSDK + nanonext only).
.addin_ask_form_server <- function(form_url, timeout_seconds = 600) {
  if (!requireNamespace("ClaudeAgentSDK", quietly = TRUE) ||
      !("mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))) return(NULL)
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script) || !file.exists(script)) return(NULL)
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  args <- list("--vanilla", script)
  list(
    type = "stdio",
    command = rscript,
    args = args,
    env = list(
      CLAUDE_ADDIN_FORM_URL = form_url,
      CLAUDE_ADDIN_FORM_TIMEOUT_MS = as.character(as.integer((timeout_seconds + 30) * 1000)),
      R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)
    ),
    # The CLI's per-server tool-call limit; the service, not the CLI, decides.
    timeout = as.integer((timeout_seconds + 60) * 1000)
  )
}

# Per browser session: Stop cancels that thread's forms; closing the session
# cancels forms whose run belonged to it.
.bind_ask_form <- function(service, session, input_id, owner) {
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    thread_id <- if (is.list(msg)) msg$threadId else NULL
    if (.ask_form_string(thread_id)) service$cancel_thread(thread_id, owner)
  }, ignoreNULL = TRUE, ignoreInit = TRUE)
  session$onSessionEnded(function() service$cancel_owner(owner))
  invisible(TRUE)
}
