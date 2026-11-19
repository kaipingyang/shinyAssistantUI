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
# Structural limits for model-authored `pattern`s, checked before TRE sees them:
# TRE expands counted repeats and alternatives into automaton states, so nested
# repeats such as (a{255}){255} exhaust memory and long alternations are slow.
.ASK_FORM_PATTERN_MAX <- 200L
.ASK_FORM_PATTERN_MAX_REPEAT <- 50L
.ASK_FORM_PATTERN_MAX_EXPANSION <- 100L
.ASK_FORM_PATTERN_MAX_ALTERNATIVES <- 20L
.ASK_FORM_PATTERN_MAX_ANSWER <- 500L

# Returns NULL when the pattern is acceptable, otherwise the reason. PURE.
.ask_form_pattern_problem <- function(pattern) {
  if (nchar(pattern) > .ASK_FORM_PATTERN_MAX) {
    return(sprintf("must be at most %d characters", .ASK_FORM_PATTERN_MAX))
  }
  chars <- strsplit(pattern, "", fixed = TRUE)[[1L]]
  n <- length(chars)
  i <- 1L
  group_mult <- numeric()   # per open group: largest {} expansion inside it
  last_mult <- 1            # expansion of the atom just read
  alternatives <- 0L
  while (i <= n) {
    ch <- chars[[i]]
    atom_mult <- 1
    if (ch == "\\") {
      if (i < n && grepl("[1-9AZzbBGk]", chars[[i + 1L]])) {
        return("must not use backreferences or \\A, \\Z, \\z, \\b, \\B, \\G, \\k; use ^ and $ for anchors")
      }
      i <- i + 2L
    } else if (ch == "[") {
      j <- i + 1L
      if (j <= n && chars[[j]] == "^") j <- j + 1L
      if (j <= n && chars[[j]] == "]") j <- j + 1L
      while (j <= n && chars[[j]] != "]") {
        if (chars[[j]] == "[" && j < n && chars[[j + 1L]] %in% c(":", ".", "=")) {
          close <- regexpr(paste0(chars[[j + 1L]], "]"), substr(pattern, j + 2L, n), fixed = TRUE)
          if (close < 0) return("has an unterminated bracket expression")
          j <- j + 2L + close + 1L
        } else if (chars[[j]] == "\\" && j < n && grepl("[1-9]", chars[[j + 1L]])) {
          return("must not use backreferences")
        } else j <- j + 1L
      }
      if (j > n) return("has an unterminated bracket expression")
      i <- j + 1L
    } else if (ch == "(") {
      group_mult <- c(group_mult, 1)
      i <- i + 1L
      if (i <= n && chars[[i]] == "?") i <- i + 1L   # (?:...) and inline flags
      next
    } else if (ch == ")") {
      if (!length(group_mult)) return("has unbalanced parentheses")
      atom_mult <- group_mult[length(group_mult)]
      group_mult <- group_mult[-length(group_mult)]
      i <- i + 1L
    } else if (ch == "|") {
      alternatives <- alternatives + 1L
      if (alternatives >= .ASK_FORM_PATTERN_MAX_ALTERNATIVES) {
        return(sprintf("must have fewer than %d alternatives", .ASK_FORM_PATTERN_MAX_ALTERNATIVES))
      }
      i <- i + 1L
    } else if (ch == "{") {
      close <- regexpr("}", substr(pattern, i, n), fixed = TRUE)
      if (close < 0) return("has an unterminated {} repeat")
      counts <- suppressWarnings(as.numeric(strsplit(substr(pattern, i + 1L, i + close - 2L), ",", fixed = TRUE)[[1L]]))
      if (any(counts[!is.na(counts)] > .ASK_FORM_PATTERN_MAX_REPEAT)) {
        return(sprintf("must not repeat more than %d times in {}", .ASK_FORM_PATTERN_MAX_REPEAT))
      }
      # TRE expands {} repeats into automaton states; nesting multiplies the size.
      known <- counts[!is.na(counts)]
      total <- last_mult * (if (length(known)) max(known) else 1)
      if (total > .ASK_FORM_PATTERN_MAX_EXPANSION) {
        return(sprintf("nested {} repeats must expand to at most %d", .ASK_FORM_PATTERN_MAX_EXPANSION))
      }
      atom_mult <- total
      i <- i + close
    } else {
      i <- i + 1L
    }
    if (length(group_mult)) group_mult[length(group_mult)] <- max(group_mult[length(group_mult)], atom_mult)
    last_mult <- atom_mult
  }
  if (length(group_mult)) return("has unbalanced parentheses")
  NULL
}

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
    num_opt <- function(key) {
      value <- f[[key]]
      if (is.null(value)) return(NULL)
      value <- suppressWarnings(as.numeric(unlist(value, use.names = FALSE)))
      if (length(value) != 1L || !is.finite(value)) return(NA_real_)
      value
    }
    bounds <- lapply(c(min = "min", max = "max", step = "step"), num_opt)
    if (any(!vapply(bounds, is.null, TRUE)) && !identical(type, "number")) {
      return(sprintf("Field `%s`: `min`, `max` and `step` apply only to number fields.", name))
    }
    if (any(vapply(bounds, function(b) !is.null(b) && is.na(b), TRUE))) {
      return(sprintf("Field `%s`: `min`, `max` and `step` must be finite numbers.", name))
    }
    if (!is.null(bounds$min) && !is.null(bounds$max) && bounds$min > bounds$max) {
      return(sprintf("Field `%s`: `min` must not exceed `max`.", name))
    }
    if (!is.null(bounds$step) && bounds$step <= 0) {
      return(sprintf("Field `%s`: `step` must be positive.", name))
    }
    pattern <- as.character(.ask_form_scalar(f$pattern, ""))
    if (is.na(pattern)) pattern <- ""
    if (nzchar(pattern)) {
      if (!type %in% c("text", "textarea")) {
        return(sprintf("Field `%s`: `pattern` applies only to text and textarea fields.", name))
      }
      problem <- .ask_form_pattern_problem(pattern)
      if (!is.null(problem)) return(sprintf("Field `%s`: `pattern` %s.", name, problem))
      # POSIX extended regex (TRE) after the structural checks above: matching time
      # stays linear in the input, unlike backtracking engines.
      compiles <- tryCatch({ grepl(pattern, "", perl = FALSE); TRUE }, error = function(e) FALSE,
                           warning = function(w) FALSE)
      if (!compiles) return(sprintf("Field `%s`: `pattern` is not a valid regular expression.", name))
    }
    allow_other <- isTRUE(as.logical(.ask_form_scalar(f$allow_other, FALSE)))
    if (allow_other && !identical(type, "select")) {
      return(sprintf("Field `%s`: `allow_other` applies only to select fields.", name))
    }
    placeholder <- as.character(.ask_form_scalar(f$placeholder, ""))
    if (is.na(placeholder)) placeholder <- ""
    if (nchar(placeholder) > 200L) return(sprintf("Field `%s`: `placeholder` must be at most 200 characters.", name))
    if (nzchar(placeholder) && !type %in% c("text", "textarea", "number")) {
      return(sprintf("Field `%s`: `placeholder` applies only to text, textarea and number fields.", name))
    }
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
      help = substr(as.character(.ask_form_scalar(f$help, "")), 1L, 500L),
      placeholder = placeholder,
      min = bounds$min, max = bounds$max, step = bounds$step,
      pattern = pattern,
      pattern_hint = substr(as.character(.ask_form_scalar(f$pattern_hint, "")), 1L, 200L),
      allow_other = allow_other
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
    if (nzchar(field$placeholder %||% "") && identical(component$component, "TextField")) {
      component$placeholder <- field$placeholder
    }
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
    if (isTRUE(field$allow_other)) {
      # Free-text alternative, bound outside /values so it cannot collide with a field.
      other_id <- paste0("other-", field$name)
      components <- c(components, list(list(
        id = other_id, component = "TextField", label = paste0(field$label, ": other value"),
        value = list(path = paste0("/other/", field$name)), placeholder = "Or type another value"
      )))
      field_ids <- c(field_ids, other_id)
    }
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
  other_fields <- Filter(function(field) isTRUE(field$allow_other), spec)
  submit_context <- list(formId = form_id, values = value_bindings)
  if (length(other_fields)) {
    submit_context$other <- stats::setNames(
      lapply(other_fields, function(field) list(path = paste0("/other/", field$name))),
      vapply(other_fields, `[[`, "", "name"))
  }
  components <- c(components, list(
    list(id = "error", component = "Text", text = list(path = "/error")),
    list(id = "submit", component = "Button", text = submit_label,
         action = list(event = list(name = "ask_form.submit", context = submit_context))),
    list(id = "cancel", component = "Button", text = "Cancel",
         action = list(event = list(name = "ask_form.cancel", context = list(formId = form_id)))),
    list(id = "actions", component = "Row", children = list("submit", "cancel"))
  ))
  root <- list(id = "root", component = "Column",
               children = as.list(c("title", field_ids, "error", "actions")))
  values <- stats::setNames(lapply(spec, .ask_form_initial), vapply(spec, `[[`, "", "name"))
  model <- list(values = values, error = "")
  if (length(other_fields)) {
    # A default outside the listed choices starts in the other-value input.
    model$other <- stats::setNames(lapply(other_fields, function(field) {
      if (nzchar(field$default) && !field$default %in% field$choices) field$default else ""
    }), vapply(other_fields, `[[`, "", "name"))
  }
  list(
    list(version = "v0.9.1", createSurface = list(
      surfaceId = form_id, catalogId = "urn:shinyassistantui:a2ui:catalog:v1",
      sendDataModel = FALSE
    )),
    list(version = "v0.9.1", updateComponents = list(
      surfaceId = form_id, components = c(list(root), components)
    )),
    list(version = "v0.9.1", updateDataModel = list(
      surfaceId = form_id, path = "/", value = model
    ))
  )
}

# Coerce and validate submitted values. Returns list(values=, problems=). PURE.
.ask_form_collect <- function(spec, raw, other = list()) {
  raw <- if (is.list(raw)) raw else list()
  other <- if (is.list(other)) other else list()
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
        } else {
          if (!is.null(field$min) && number < field$min) {
            problems <- c(problems, sprintf("%s must be at least %s.", field$label, format(field$min)))
          }
          if (!is.null(field$max) && number > field$max) {
            problems <- c(problems, sprintf("%s must be at most %s.", field$label, format(field$max)))
          }
          if (!is.null(field$step)) {
            base <- field$min %||% 0
            ratio <- (number - base) / field$step
            # Very large ratios cannot be checked reliably in double precision.
            off_grid <- !is.finite(ratio) || abs(ratio) > 1e12 ||
              abs(ratio - round(ratio)) > 1e-9
            if (off_grid) {
              problems <- c(problems, sprintf("%s must be a multiple of %s%s.", field$label,
                                              format(field$step),
                                              if (base != 0) paste0(" from ", format(base)) else ""))
            }
          }
          number
        }
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
        typed <- if (isTRUE(field$allow_other)) trimws(text_of(other[[field$name]])) else ""
        if (nchar(typed) > 200L) {
          problems <- c(problems, sprintf("%s: the other value is too long.", field$label))
          typed <- substr(typed, 1L, 200L)
        }
        if (nzchar(typed)) typed
        else if (nzchar(pick) && !pick %in% field$choices) {
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
        } else {
          has_pattern <- nzchar(field$pattern %||% "")
          if (has_pattern && nchar(text) > .ASK_FORM_PATTERN_MAX_ANSWER) {
            problems <- c(problems, sprintf("%s is too long.", field$label))
          }
          matched <- if (has_pattern && nzchar(text) && nchar(text) <= .ASK_FORM_PATTERN_MAX_ANSWER) {
            tryCatch(isTRUE(grepl(field$pattern, text, perl = FALSE)),
                     error = function(e) FALSE, warning = function(w) FALSE)
          } else TRUE
          if (!matched) {
            hint <- if (nzchar(field$pattern_hint %||% "")) field$pattern_hint else "the expected format"
            problems <- c(problems, sprintf("%s: expected %s.", field$label, hint))
          }
          text
        }
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
    # A repeated delivery of the same request keeps the open form and answers on
    # the newest channel (the old one may no longer be read).
    for (open_id in ls(pending)) {
      open_entry <- get0(open_id, envir = pending, inherits = FALSE)
      if (!is.null(open_entry) && identical(open_entry$request_id, request_id) &&
          identical(open_entry$thread_id, req$thread_id)) {
        open_entry$respond <- respond
        assign(open_id, open_entry, envir = pending)
        return(invisible(TRUE))
      }
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
    collected <- .ask_form_collect(entry$spec, context$values, context$other)
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
