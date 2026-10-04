# Experimental A2UI v0.9-family transport over the existing Shiny socket.
# Wire input accepts v0.9/v0.9.1; persisted snapshots/checkpoints remain canonical v0.9.

.a2ui_id <- function(value) {
  is.character(value) && length(value) == 1L && !is.na(value) &&
    nzchar(value) && nchar(value, type = "bytes") <= 128L &&
    grepl("^[A-Za-z0-9][A-Za-z0-9._:@/-]*$", value)
}

.a2ui_json_safe <- function(value, depth = 0L) {
  if (depth > 32L) return(FALSE)
  if (is.null(value) || is.logical(value)) return(TRUE)
  if (is.character(value)) return(all(nchar(value, type = "bytes") <= 16L * 1024L))
  if (is.numeric(value)) return(all(is.finite(value)))
  if (!is.list(value)) return(FALSE)
  nms <- names(value)
  if (!is.null(nms) && any(nms %in% c("__proto__", "prototype", "constructor"))) return(FALSE)
  if (length(value) > 1000L) return(FALSE)
  all(vapply(value, .a2ui_json_safe, logical(1), depth = depth + 1L))
}

.a2ui_operation_kind <- function(operation) {
  if (!is.list(operation) || !operation$version %in% c("v0.9", "v0.9.1")) return(NULL)
  keys <- setdiff(names(operation), "version")
  if (length(names(operation)) != 2L || length(keys) != 1L ||
      !keys %in% c("createSurface", "updateComponents", "updateDataModel", "deleteSurface")) return(NULL)
  payload <- operation[[keys]]
  if (!is.list(payload) || !.a2ui_id(payload$surfaceId)) return(NULL)
  keys
}

.a2ui_exact_names <- function(value, allowed, required = allowed) {
  is.list(value) && !is.null(names(value)) && !anyDuplicated(names(value)) &&
    all(names(value) %in% allowed) && all(required %in% names(value))
}

.a2ui_pointer_valid <- function(value, allow_relative = FALSE) {
  if (!is.character(value) || length(value) != 1L || is.na(value)) return(FALSE)
  if (!startsWith(value, "/")) {
    if (!isTRUE(allow_relative) || !nzchar(value)) return(FALSE)
    value <- paste0("/", value)
  }
  if (identical(value, "/")) return(TRUE)
  raw <- strsplit(substring(value, 2L), "/", fixed = TRUE)[[1L]]
  if (any(grepl("~([^01]|$)", raw, perl = TRUE))) return(FALSE)
  decoded <- gsub("~0", "~", gsub("~1", "/", raw, fixed = TRUE), fixed = TRUE)
  !any(decoded %in% c("__proto__", "prototype", "constructor"))
}

.a2ui_embedded_pointers_valid <- function(value) {
  if (!is.list(value)) return(TRUE)
  nms <- names(value)
  for (i in seq_along(value)) {
    if (!is.null(nms) && identical(nms[[i]], "path")) {
      if (!.a2ui_pointer_valid(value[[i]], allow_relative = TRUE)) return(FALSE)
    } else if (!.a2ui_embedded_pointers_valid(value[[i]])) return(FALSE)
  }
  TRUE
}

.a2ui_validate_components <- function(components) {
  allowed <- c("Text", "Image", "Icon", "Row", "Column", "List", "Card", "Divider",
               "Button", "TextField", "CheckBox", "ChoicePicker", "DateTimeInput", "Slider")
  if (!is.list(components) || !is.null(names(components)) || length(components) > 500L) {
    stop("A2UI components are invalid.", call. = FALSE)
  }
  ids <- character()
  for (component in components) {
    if (!is.list(component) || !.a2ui_id(component$id) ||
        !is.character(component$component) || length(component$component) != 1L ||
        !component$component %in% allowed || !.a2ui_embedded_pointers_valid(component)) {
      stop("A2UI component is invalid.", call. = FALSE)
    }
    ids <- c(ids, component$id)
  }
  if (anyDuplicated(ids)) stop("A2UI component ids must be unique.", call. = FALSE)
  by_id <- setNames(components, ids)
  references <- function(component) {
    result <- character()
    if (.a2ui_id(component$child)) result <- c(result, component$child)
    children <- component$children
    if (is.list(children) && !is.null(names(children))) {
      template <- if (is.list(children$template)) children$template else children
      if (.a2ui_id(template$componentId)) result <- c(result, template$componentId)
    }
    if (is.list(children) && is.null(names(children))) {
      result <- c(result, vapply(Filter(.a2ui_id, children), as.character, ""))
    }
    result
  }
  visit <- function(id, active = character(), depth = 0L) {
    if (depth > 32L) stop("A2UI component tree exceeds depth 32.", call. = FALSE)
    if (id %in% active) stop("A2UI component cycle detected.", call. = FALSE)
    component <- by_id[[id]]
    if (is.null(component)) return(invisible(TRUE))
    for (child in references(component)) visit(child, c(active, id), depth + 1L)
    invisible(TRUE)
  }
  for (id in ids) visit(id)
  invisible(TRUE)
}
.a2ui_validate_operations <- function(operations) {
  if (!is.list(operations) || !is.null(names(operations)) ||
      length(operations) > 64L || !.a2ui_json_safe(operations)) {
    stop("A2UI operations must be bounded plain JSON.", call. = FALSE)
  }
  kinds <- vapply(operations, function(operation) {
    kind <- .a2ui_operation_kind(operation)
    if (is.null(kind)) stop("A2UI operation must contain v0.9/v0.9.1 and one standard key.", call. = FALSE)
    payload <- operation[[kind]]
    if (identical(kind, "createSurface")) {
      if (!.a2ui_exact_names(payload, c(
            "surfaceId", "catalogId", "theme", "attachDataModel", "sendDataModel"
          ), "surfaceId")) {
        stop("A2UI createSurface payload is invalid.", call. = FALSE)
      }
      catalogs <- c(
        "urn:shinyassistantui:a2ui:catalog:v1",
        "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json",
        "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json"
      )
      catalog_valid <- !("catalogId" %in% names(payload)) ||
        (is.character(payload$catalogId) && length(payload$catalogId) == 1L &&
         !is.na(payload$catalogId) && payload$catalogId %in% catalogs)
      if (!catalog_valid ||
          isTRUE(payload$sendDataModel) || isTRUE(payload$attachDataModel) ||
          ("sendDataModel" %in% names(payload) && !identical(payload$sendDataModel, FALSE)) ||
          ("attachDataModel" %in% names(payload) && !identical(payload$attachDataModel, FALSE))) {
        stop("A2UI sendDataModel is unsupported or catalogId is invalid.", call. = FALSE)
      }
    } else if (identical(kind, "updateComponents")) {
      if (!.a2ui_exact_names(payload, c("surfaceId", "components"))) stop("A2UI updateComponents payload is invalid.", call. = FALSE)
      .a2ui_validate_components(payload$components)
    } else if (identical(kind, "updateDataModel")) {
      if (!.a2ui_exact_names(payload, c("surfaceId", "path", "contents", "value", "data"), "surfaceId") ||
          sum(c("contents", "value", "data") %in% names(payload)) != 1L ||
          !.a2ui_pointer_valid(payload$path %||% "/")) stop("A2UI updateDataModel payload is invalid.", call. = FALSE)
    } else if (!.a2ui_exact_names(payload, "surfaceId")) {
      stop("A2UI deleteSurface payload is invalid.", call. = FALSE)
    }
    kind
  }, "")
  encoded <- as.character(jsonlite::toJSON(operations, auto_unbox = TRUE, null = "null", digits = NA))
  if (nchar(encoded, type = "bytes") > 256L * 1024L) stop("A2UI envelope exceeds 256 KiB.", call. = FALSE)
  digest <- .native_sha256(charToRaw(encoded))
  if (is.null(digest)) stop("A2UI SHA-256 is unavailable.", call. = FALSE)
  list(kinds = kinds, encoded = encoded, digest = digest)
}

.a2ui_sort_keys <- function(value) {
  if (!is.list(value)) return(value)
  if (is.null(names(value))) return(lapply(value, .a2ui_sort_keys))
  ordered <- value[order(names(value))]
  lapply(ordered, .a2ui_sort_keys)
}

.a2ui_digest <- function(value) {
  encoded <- as.character(jsonlite::toJSON(
    .a2ui_sort_keys(value), auto_unbox = TRUE, null = "null", digits = NA
  ))
  .native_sha256(charToRaw(encoded))
}

.a2ui_pointer_get <- function(model, path) {
  if (!.a2ui_pointer_valid(path)) return(NULL)
  if (identical(path, "/")) return(model)
  parts <- strsplit(substring(path, 2L), "/", fixed = TRUE)[[1L]]
  parts <- gsub("~0", "~", gsub("~1", "/", parts, fixed = TRUE), fixed = TRUE)
  value <- model
  for (part in parts) {
    if (!is.list(value)) return(NULL)
    if (is.null(names(value))) {
      index <- suppressWarnings(as.integer(part)) + 1L
      if (is.na(index) || index < 1L || index > length(value)) return(NULL)
      value <- value[[index]]
    } else {
      if (!part %in% names(value)) return(NULL)
      value <- value[[part]]
    }
  }
  value
}

.a2ui_pointer_set <- function(model, path, leaf) {
  if (!.a2ui_pointer_valid(path)) return(model)
  if (identical(path, "/")) return(leaf)
  parts <- strsplit(substring(path, 2L), "/", fixed = TRUE)[[1L]]
  parts <- gsub("~0", "~", gsub("~1", "/", parts, fixed = TRUE), fixed = TRUE)
  set_at <- function(value, remaining) {
    if (!length(remaining)) return(leaf)
    key <- remaining[[1L]]
    rest <- remaining[-1L]
    if (is.null(value) || !is.list(value)) value <- list()
    if (is.null(names(value)) && grepl("^(0|[1-9][0-9]*)$", key)) {
      index <- as.integer(key) + 1L
      if (index > 1000L) return(value)
      length(value) <- max(length(value), index)
      value[[index]] <- set_at(value[[index]], rest)
    } else {
      if (is.null(names(value))) names(value) <- rep("", length(value))
      value[[key]] <- set_at(value[[key]], rest)
    }
    value
  }
  set_at(model, parts)
}

.a2ui_project_action_context <- function(template, submitted) {
  project <- function(expected, actual, depth = 0L) {
    if (depth > 32L || (is.list(expected) && !is.null(names(expected)) && anyDuplicated(names(expected)))) {
      return(list(ok = FALSE, value = NULL))
    }
    dynamic_path <- is.list(expected) && identical(names(expected), "path") &&
      .a2ui_pointer_valid(expected$path, allow_relative = TRUE)
    dynamic_call <- is.list(expected) &&
      .a2ui_exact_names(expected, c("call", "args", "returnType", "catalogId"), "call") &&
      is.character(expected$call) && length(expected$call) == 1L &&
      !is.na(expected$call) && nzchar(expected$call) &&
      (is.null(expected$args) || (is.list(expected$args) && !is.null(names(expected$args))))
    if (dynamic_path || dynamic_call) {
      return(list(ok = .a2ui_json_safe(actual), value = actual))
    }
    if (!is.list(expected)) return(list(ok = TRUE, value = expected))
    if (!is.list(actual)) return(list(ok = FALSE, value = NULL))
    expected_names <- names(expected)
    actual_names <- names(actual)
    if (is.null(expected_names) != is.null(actual_names)) {
      return(list(ok = FALSE, value = NULL))
    }
    if (is.null(expected_names)) {
      if (length(expected) != length(actual)) return(list(ok = FALSE, value = NULL))
      values <- Map(function(left, right) project(left, right, depth + 1L), expected, actual)
      if (!all(vapply(values, `[[`, logical(1), "ok"))) return(list(ok = FALSE, value = NULL))
      return(list(ok = TRUE, value = lapply(values, `[[`, "value")))
    }
    if (anyDuplicated(actual_names) || !setequal(expected_names, actual_names)) {
      return(list(ok = FALSE, value = NULL))
    }
    values <- lapply(expected_names, function(name) {
      project(expected[[name]], actual[[name]], depth + 1L)
    })
    if (!all(vapply(values, `[[`, logical(1), "ok"))) return(list(ok = FALSE, value = NULL))
    result <- lapply(values, `[[`, "value")
    names(result) <- expected_names
    list(ok = TRUE, value = result)
  }
  project(template, submitted)
}

.a2ui_handle_renderer_error <- function(handler, message, is_authorized) {
  if (!is.function(handler) || !is.function(is_authorized) || !is.list(message) ||
      !.a2ui_exact_names(message, c("transportVersion", "threadId", "version", "error")) ||
      !identical(message$transportVersion, 1L) || !.a2ui_id(message$threadId) ||
      !identical(message$version, "v0.9.1") || !is.list(message$error) ||
      !.a2ui_exact_names(message$error, c("code", "surfaceId", "path", "message")) ||
      !identical(message$error$code, "VALIDATION_FAILED") ||
      !.a2ui_id(message$error$surfaceId) || !.a2ui_pointer_valid(message$error$path) ||
      nchar(message$error$path, type = "bytes") > 1024L ||
      !is.character(message$error$message) || length(message$error$message) != 1L ||
      is.na(message$error$message) || !nzchar(message$error$message) ||
      nchar(message$error$message, type = "bytes") > 1024L) return(invisible(FALSE))
  authorized <- tryCatch(
    isTRUE(is_authorized(message$threadId, message$error$surfaceId)),
    error = function(error) FALSE
  )
  if (!authorized) return(invisible(FALSE))
  tryCatch({
    .call_compatible_callback(handler, list(
      code = message$error$code,
      thread_id = message$threadId,
      surface_id = message$error$surfaceId,
      path = message$error$path,
      message = "A2UI envelope failed renderer validation."
    ))
    invisible(TRUE)
  }, error = function(error) invisible(FALSE))
}

.a2ui_materialize_context <- function(value, model) {
  if (!is.list(value)) return(value)
  if (identical(names(value), "path") && .a2ui_pointer_valid(value$path)) {
    return(.a2ui_pointer_get(model, value$path))
  }
  result <- lapply(value, .a2ui_materialize_context, model = model)
  names(result) <- names(value)
  result
}

.a2ui_component_actions <- function(components) {
  result <- list()
  if (!is.list(components)) return(result)
  for (component in components) {
    if (!is.list(component) || !.a2ui_id(component$id) || !identical(component$component, "Button")) next
    action <- component$action
    event <- if (is.list(action) && is.list(action$event)) action$event else action
    name <- if (is.character(event) && length(event) == 1L) event else if (is.list(event)) event$name else NULL
    if (is.character(name) && length(name) == 1L && grepl("^[A-Za-z][A-Za-z0-9_.:-]{0,127}$", name)) {
      result[[component$id]] <- list(name = name, context = if (is.list(event)) event$context else NULL)
    }
  }
  result
}

.new_a2ui_transport <- function(session, input_id, ui_owner, action_handler = NULL, now = function() as.numeric(Sys.time())) {
  threads <- new.env(hash = TRUE, parent = emptyenv())
  action_replay <- new.env(hash = TRUE, parent = emptyenv())
  action_times <- new.env(hash = TRUE, parent = emptyenv())

.a2ui_part_candidate <- function(part) {
  if (!is.list(part)) return(FALSE)
  if ("a2ui" %in% (names(part) %||% character())) return(TRUE)
  artifact <- if (is.list(part$artifact)) part$artifact else NULL
  identical(part$type, "tool-call") && (
    (is.character(part$toolCallId) && length(part$toolCallId) == 1L &&
       !is.na(part$toolCallId) && startsWith(part$toolCallId, "a2ui:")) ||
    (is.list(artifact) && "shinyA2ui" %in% (names(artifact) %||% character()))
  )
}

.a2ui_marker_from_part <- function(part) {
  if (!is.list(part)) return(NULL)
  if (identical(part$type, "generative-ui") && is.list(part$a2ui)) return(part$a2ui)
  artifact <- part$artifact
  marker <- if (is.list(artifact)) artifact$shinyA2ui else NULL
  operations <- if (is.list(artifact)) artifact$a2ui else NULL
  if (!identical(part$type, "tool-call") || !identical(part$toolName, "present") ||
      !is.list(part$args) || is.null(names(part$args)) || anyDuplicated(names(part$args)) ||
      !is.list(marker) || !is.list(operations) ||
      !identical(part$toolCallId, paste0("a2ui:", marker$surfaceId %||% "")) ||
      !identical(.a2ui_digest(operations), .a2ui_digest(marker$snapshot))) return(NULL)
  marker
}

.a2ui_valid_marker <- function(part) {
  marker <- .a2ui_marker_from_part(part)
  if (!is.list(marker)) return(FALSE)
  marker_names <- c(
    "kind", "schemaVersion", "transportVersion", "protocolVersion", "surfaceId",
    "epoch", "revision", "lastSequence", "recentEventIds", "snapshot", "snapshotDigest", "anchor"
  )
  integer_scalar <- function(value, positive = TRUE) {
    is.numeric(value) && length(value) == 1L && is.finite(value) &&
      abs(value) <= 2^53 - 1 && value %% 1 == 0 &&
      if (positive) value > 0 else value >= 0
  }
  if (!.a2ui_exact_names(marker, marker_names) || !identical(marker$kind, "surface") ||
      !identical(marker$schemaVersion, 1L) || !identical(marker$transportVersion, 1L) ||
      !identical(marker$protocolVersion, "v0.9") || !.a2ui_id(marker$surfaceId) ||
      !integer_scalar(marker$epoch) || !integer_scalar(marker$revision) ||
      !integer_scalar(marker$lastSequence) || marker$epoch > marker$revision ||
      marker$revision > marker$lastSequence || !is.list(marker$recentEventIds) ||
      length(marker$recentEventIds) > 64L ||
      !all(vapply(marker$recentEventIds, .a2ui_id, logical(1))) ||
      !is.list(marker$anchor) || !.a2ui_exact_names(marker$anchor, c("runId", "messageId")) ||
      !.a2ui_id(marker$anchor$runId) || !.a2ui_id(marker$anchor$messageId) ||
      !is.character(marker$snapshotDigest) || length(marker$snapshotDigest) != 1L ||
      !grepl("^[0-9a-f]{64}$", marker$snapshotDigest)) return(FALSE)
  valid_snapshot <- tryCatch({
    validated <- .a2ui_validate_operations(marker$snapshot)
    kinds <- vapply(marker$snapshot, .a2ui_operation_kind, "")
    ids <- vapply(seq_along(marker$snapshot), function(i) marker$snapshot[[i]][[kinds[[i]]]]$surfaceId, "")
    length(marker$snapshot) > 0L && all(ids == marker$surfaceId) &&
      any(kinds == "createSurface") && !any(kinds == "deleteSurface") &&
      identical(.a2ui_digest(marker$snapshot), marker$snapshotDigest)
  }, error = function(error) FALSE)
  isTRUE(valid_snapshot)
}
  event_counter <- 0L

  thread_state <- function(thread_id) {
    state <- get0(thread_id, envir = threads, inherits = FALSE)
    if (!is.null(state)) return(state)
    state <- new.env(parent = emptyenv())
    state$last_sequence <- 0
    state$generation <- 0
    state$ledger <- list()
    state$events <- new.env(hash = TRUE, parent = emptyenv())
    state$surfaces <- new.env(hash = TRUE, parent = emptyenv())
    state$activity_buckets <- list()
    state$activity_bucket_order <- character()
    state$activity_owned <- character()
    state$activity_events <- new.env(hash = TRUE, parent = emptyenv())
    state$activity_event_order <- character()
    assign(thread_id, state, envir = threads)
    state
  }

  prune_activity_events <- function(state) {
    ids <- ls(state$activity_events, all.names = TRUE)
    expired <- ids[vapply(ids, function(event_id) {
      entry <- get(event_id, envir = state$activity_events, inherits = FALSE)
      !is.null(entry$envelope) && !exists(event_id, envir = state$events, inherits = FALSE)
    }, logical(1))]
    if (length(expired)) {
      rm(list = expired, envir = state$activity_events)
      state$activity_event_order <- setdiff(state$activity_event_order, expired)
    }
    invisible(TRUE)
  }

  apply_authority <- function(state, operations, sequence, run_id) {
    for (operation in operations) {
      kind <- .a2ui_operation_kind(operation)
      payload <- operation[[kind]]
      surface_id <- payload$surfaceId
      previous <- get0(surface_id, envir = state$surfaces, inherits = FALSE)
      if (identical(kind, "createSurface")) {
        assign(surface_id, list(
          surfaceId = surface_id, epoch = sequence, revision = sequence,
          deleted = FALSE, runId = run_id, components = list(), actions = list(), dataModel = list()
        ), envir = state$surfaces)
      } else if (identical(kind, "updateComponents") && !is.null(previous) && !isTRUE(previous$deleted)) {
        previous$revision <- sequence
        existing <- previous$components %||% list()
        by_id <- setNames(existing, vapply(existing, function(component) as.character(component$id %||% ""), ""))
        for (component in payload$components %||% list()) by_id[[component$id]] <- component
        previous$components <- unname(by_id[nzchar(names(by_id))])
        previous$actions <- .a2ui_component_actions(previous$components)
        assign(surface_id, previous, envir = state$surfaces)
      } else if (identical(kind, "updateDataModel") && !is.null(previous) && !isTRUE(previous$deleted)) {
        previous$revision <- sequence
        path <- payload$path %||% "/"
        value_name <- intersect(c("contents", "value", "data"), names(payload))[[1L]]
        previous$dataModel <- .a2ui_pointer_set(previous$dataModel, path, payload[[value_name]])
        assign(surface_id, previous, envir = state$surfaces)
      } else if (identical(kind, "deleteSurface") && !is.null(previous)) {
        previous$revision <- sequence
        previous$deleted <- TRUE
        previous$deletedAtSequence <- sequence
        previous$actions <- list()
        assign(surface_id, previous, envir = state$surfaces)
      }
    }
  }

  validate_lifecycle <- function(state, operations) {
    ids <- ls(state$surfaces, all.names = TRUE)
    live <- ids[vapply(ids, function(id) {
      !isTRUE(get(id, envir = state$surfaces, inherits = FALSE)$deleted)
    }, logical(1))]
    for (index in seq_along(operations)) {
      operation <- operations[[index]]
      kind <- .a2ui_operation_kind(operation)
      id <- operation[[kind]]$surfaceId
      if (identical(kind, "createSurface")) {
        if (id %in% live) stop("A2UI surface is already active.", call. = FALSE)
        live <- union(live, id)
      } else {
        if (!id %in% live) stop("A2UI operation references a missing surface.", call. = FALSE)
        if (identical(kind, "deleteSurface")) live <- setdiff(live, id)
      }
    }
    invisible(TRUE)
  }

  checkpoint <- function(thread_id) {
    state <- thread_state(thread_id)
    lineage <- lapply(ls(state$surfaces, all.names = TRUE), function(surface_id) {
      surface <- get(surface_id, envir = state$surfaces)
      compact <- surface[c("surfaceId", "epoch", "revision")]
      if (isTRUE(surface$deleted)) compact$deletedAtSequence <- surface$deletedAtSequence
      compact
    })
    list(
      transportVersion = 1L, protocolVersion = "v0.9", schemaVersion = 1L,
      lastAcceptedSequence = state$last_sequence, generation = state$generation,
      eventLedger = lapply(state$ledger, function(entry) entry[c("eventId", "sequence", "digest")]),
      lineage = lineage
    )
  }

  compact_surfaces <- function(state) {
    ids <- ls(state$surfaces, all.names = TRUE)
    deleted <- ids[vapply(ids, function(id) isTRUE(get(id, envir = state$surfaces)$deleted), logical(1))]
    if (length(deleted) <= 128L) return(invisible(TRUE))
    sequences <- vapply(deleted, function(id) as.numeric(
      get(id, envir = state$surfaces)$deletedAtSequence %||% 0
    ), numeric(1))
    keep <- deleted[order(sequences, decreasing = TRUE)][seq_len(128L)]
    remove <- setdiff(deleted, keep)
    if (length(remove)) rm(list = remove, envir = state$surfaces)
    invisible(TRUE)
  }

  send <- function(thread_id, run_id, operations, event_id = NULL, sequence = NULL) {
    if (!.a2ui_id(thread_id) || !.a2ui_id(run_id)) stop("A2UI thread/run id is invalid.", call. = FALSE)
    validated <- .a2ui_validate_operations(operations)
    state <- thread_state(thread_id)
    live <- ls(state$surfaces, all.names = TRUE)
    live <- live[vapply(live, function(id) !isTRUE(get(id, envir = state$surfaces)$deleted), logical(1))]
    for (operation in operations) {
      kind <- .a2ui_operation_kind(operation)
      id <- operation[[kind]]$surfaceId
      if (identical(kind, "createSurface")) live <- union(live, id)
      if (identical(kind, "deleteSurface")) live <- setdiff(live, id)
    }
    if (length(live) > 16L) stop("A2UI thread exceeds 16 live surfaces.", call. = FALSE)
    if (is.null(event_id)) {
      repeat {
        event_counter <<- event_counter + 1L
        event_id <- paste0("r-a2ui-", state$last_sequence + 1, "-", event_counter)
        if (!exists(event_id, envir = state$events, inherits = FALSE) &&
            !exists(event_id, envir = state$activity_events, inherits = FALSE)) break
      }
    }
    if (!.a2ui_id(event_id)) stop("A2UI event id is invalid.", call. = FALSE)
    if (exists(event_id, envir = state$activity_events, inherits = FALSE)) {
      stop("A2UI eventId is already owned by an AG-UI activity.", call. = FALSE)
    }
    prior <- get0(event_id, envir = state$events, inherits = FALSE)
    if (!is.null(prior)) {
      candidate <- list(
        transportVersion = 1L, threadId = thread_id, runId = run_id,
        eventId = event_id, sequence = prior$sequence, operations = operations
      )
      if (!identical(prior$digest, .a2ui_digest(candidate))) stop("A2UI eventId conflict.", call. = FALSE)
      if (!is.null(prior$envelope)) session$sendCustomMessage(paste0(input_id, ":a2ui"), prior$envelope)
      return(invisible(prior$envelope))
    }
    expected <- state$last_sequence + 1
    if (is.null(sequence)) sequence <- expected
    sequence <- suppressWarnings(as.numeric(sequence))
    if (length(sequence) != 1L || !is.finite(sequence) || sequence != expected || sequence %% 1 != 0) {
      stop("A2UI sequence must equal the next authoritative sequence.", call. = FALSE)
    }
    validate_lifecycle(state, operations)
    tombstone_ids <- ls(state$surfaces, all.names = TRUE)
    known_ids <- tombstone_ids
    tombstones <- setNames(vapply(tombstone_ids, function(id) {
      surface <- get(id, envir = state$surfaces)
      if (isTRUE(surface$deleted)) as.numeric(surface$deletedAtSequence %||% 0) else NA_real_
    }, numeric(1)), tombstone_ids)
    tombstones <- tombstones[is.finite(tombstones)]
    for (operation in operations) {
      kind <- .a2ui_operation_kind(operation)
      id <- operation[[kind]]$surfaceId
      if (identical(kind, "createSurface")) {
        known_ids <- union(known_ids, id)
        tombstones <- tombstones[names(tombstones) != id]
      }
      if (identical(kind, "deleteSurface") && id %in% known_ids) tombstones[[id]] <- sequence
    }
    projected_sequences <- tail(c(
      vapply(state$ledger, function(entry) as.numeric(entry$sequence), numeric(1)), sequence
    ), 64L)
    replay_floor <- if (length(projected_sequences)) projected_sequences[[1L]] else Inf
    if (sum(tombstones >= replay_floor) > 128L) {
      stop("A2UI checkpoint compaction is required before another surface change.", call. = FALSE)
    }
    envelope <- list(
      transportVersion = 1L, threadId = thread_id, runId = run_id,
      eventId = event_id, sequence = sequence, operations = operations
    )
    envelope_bytes <- nchar(as.character(jsonlite::toJSON(
      .a2ui_sort_keys(envelope), auto_unbox = TRUE, null = "null", digits = NA
    )), type = "bytes")
    if (envelope_bytes > 256L * 1024L) stop("A2UI envelope exceeds 256 KiB.", call. = FALSE)
    digest <- .a2ui_digest(envelope)
    if (is.null(digest)) stop("A2UI envelope SHA-256 is unavailable.", call. = FALSE)
    entry <- list(eventId = event_id, sequence = sequence, digest = digest, envelope = envelope)
    session$sendCustomMessage(paste0(input_id, ":a2ui"), envelope)
    state$last_sequence <- sequence
    state$generation <- state$generation + 1
    state$ledger <- tail(c(state$ledger, list(entry)), 64L)
    assign(event_id, entry, envir = state$events)
    retained_events <- vapply(state$ledger, `[[`, "", "eventId")
    forgotten <- setdiff(ls(state$events, all.names = TRUE), retained_events)
    if (length(forgotten)) rm(list = forgotten, envir = state$events)
    prune_activity_events(state)
    apply_authority(state, operations, sequence, run_id)
    compact_surfaces(state)
    invisible(envelope)
  }

  send_activity <- function(thread_id, run_id, event, event_id = NULL, sequence = NULL,
                            allow_new_surfaces = TRUE) {
    if (!is.logical(allow_new_surfaces) || length(allow_new_surfaces) != 1L ||
        is.na(allow_new_surfaces)) {
      stop("AG-UI activity new-surface authorization is invalid.", call. = FALSE)
    }
    if (!.a2ui_id(thread_id) || !.a2ui_id(run_id)) {
      stop("AG-UI activity thread/run id is invalid.", call. = FALSE)
    }
    if (!is.list(event) || is.null(names(event)) || anyDuplicated(names(event)) ||
        !identical(event$type, "ACTIVITY_SNAPSHOT")) {
      stop("AG-UI event must be an ACTIVITY_SNAPSHOT object.", call. = FALSE)
    }
    if (!identical(event$activityType, "a2ui-surface")) {
      stop("AG-UI activityType must be a2ui-surface.", call. = FALSE)
    }
    if (!is.null(event$replace) && (!is.logical(event$replace) ||
        length(event$replace) != 1L || is.na(event$replace))) {
      stop("AG-UI activity replace must be a boolean.", call. = FALSE)
    }
    message_id <- event$messageId %||% "a2ui:anonymous"
    if (!is.character(message_id) || length(message_id) != 1L || is.na(message_id) ||
        !nzchar(message_id) || nchar(message_id, type = "bytes") > 1024L) {
      stop("AG-UI activity messageId is invalid.", call. = FALSE)
    }
    content <- event$content
    if (!is.list(content) || is.null(names(content)) || anyDuplicated(names(content)) ||
        !"a2ui_operations" %in% names(content) ||
        !is.list(content$a2ui_operations) || !is.null(names(content$a2ui_operations))) {
      stop("AG-UI activity content.a2ui_operations must be an array.", call. = FALSE)
    }
    if (!.a2ui_json_safe(event)) {
      stop("AG-UI activity must contain plain JSON data.", call. = FALSE)
    }
    event_bytes <- nchar(as.character(jsonlite::toJSON(
      event, auto_unbox = TRUE, null = "null", digits = NA
    )), type = "bytes")
    if (event_bytes > 256L * 1024L) {
      stop("AG-UI activity exceeds 256 KiB.", call. = FALSE)
    }
    operations <- content$a2ui_operations
    .a2ui_validate_operations(operations)

    snapshots <- list()
    surface_order <- character()
    live <- character()
    for (operation in operations) {
      kind <- .a2ui_operation_kind(operation)
      surface_id <- operation[[kind]]$surfaceId
      if (identical(kind, "createSurface")) {
        was_live <- surface_id %in% live
        live <- union(live, surface_id)
        if (!was_live) surface_order <- c(surface_order, surface_id)
        snapshots[[surface_id]] <- list(operation)
      } else {
        if (!surface_id %in% live) {
          stop("AG-UI activity snapshot must be self-contained from createSurface.", call. = FALSE)
        }
        snapshots[[surface_id]] <- c(snapshots[[surface_id]], list(operation))
        if (identical(kind, "deleteSurface")) {
          live <- setdiff(live, surface_id)
          surface_order <- setdiff(surface_order, surface_id)
          snapshots[[surface_id]] <- NULL
        }
      }
    }
    if (length(live) > 16L) stop("AG-UI activity exceeds 16 live surfaces.", call. = FALSE)

    state <- thread_state(thread_id)
    activity_digest <- NULL
    if (!is.null(event_id)) {
      if (!.a2ui_id(event_id)) stop("AG-UI activity eventId is invalid.", call. = FALSE)
      activity_digest <- .a2ui_digest(list(
        threadId = thread_id, runId = run_id, eventId = event_id,
        event = event
      ))
      prior_activity <- get0(event_id, envir = state$activity_events, inherits = FALSE)
      if (!is.null(prior_activity)) {
        if (!identical(prior_activity$digest, activity_digest)) {
          stop("AG-UI activity eventId conflict.", call. = FALSE)
        }
        if (!is.null(prior_activity$envelope)) {
          session$sendCustomMessage(paste0(input_id, ":a2ui"), prior_activity$envelope)
        } else if (!is.null(sequence)) {
          stop("AG-UI activity sequence requires projected A2UI operations.", call. = FALSE)
        }
        return(invisible(prior_activity$envelope))
      }
      if (exists(event_id, envir = state$events, inherits = FALSE)) {
        stop("AG-UI activity eventId conflicts with an existing A2UI event.", call. = FALSE)
      }
    }
    commit_activity_event <- function(envelope) {
      if (is.null(event_id)) return(invisible(TRUE))
      assign(event_id, list(digest = activity_digest, envelope = envelope),
             envir = state$activity_events)
      state$activity_event_order <- tail(c(state$activity_event_order, event_id), 64L)
      forgotten <- setdiff(
        ls(state$activity_events, all.names = TRUE), state$activity_event_order
      )
      if (length(forgotten)) rm(list = forgotten, envir = state$activity_events)
      invisible(TRUE)
    }
    bucket_key <- .a2ui_digest(list(messageId = message_id))
    if (is.null(bucket_key)) stop("AG-UI activity messageId digest is unavailable.", call. = FALSE)
    existing_bucket <- !is.null(state$activity_buckets[[bucket_key]])
    if (identical(event$replace, FALSE) && existing_bucket) {
      if (!is.null(sequence)) {
        stop("AG-UI activity sequence requires projected A2UI operations.", call. = FALSE)
      }
      commit_activity_event(NULL)
      return(invisible(NULL))
    }

    candidate_buckets <- state$activity_buckets
    candidate_order <- state$activity_bucket_order
    if (existing_bucket) {
      candidate_buckets[[bucket_key]] <- NULL
      candidate_order <- setdiff(candidate_order, bucket_key)
    }
    if (!existing_bucket && length(candidate_order) >= 64L) {
      stop("AG-UI activity exceeds 64 message buckets.", call. = FALSE)
    }
    candidate_buckets[[bucket_key]] <- list(
      messageId = message_id, snapshots = snapshots, surfaceOrder = surface_order
    )
    candidate_order <- c(candidate_order, bucket_key)

    desired <- list()
    desired_order <- character()
    for (key in candidate_order) {
      bucket <- candidate_buckets[[key]]
      for (surface_id in bucket$surfaceOrder) {
        if (!surface_id %in% desired_order) desired_order <- c(desired_order, surface_id)
        desired[[surface_id]] <- bucket$snapshots[[surface_id]]
      }
    }
    if (length(desired_order) > 16L) {
      stop("Merged AG-UI activity exceeds 16 live surfaces.", call. = FALSE)
    }
    new_surface_ids <- desired_order[vapply(desired_order, function(surface_id) {
      surface <- get0(surface_id, envir = state$surfaces, inherits = FALSE)
      is.null(surface) || isTRUE(surface$deleted)
    }, logical(1))]
    if (length(new_surface_ids) && !allow_new_surfaces) {
      stop("Creating a new AG-UI activity surface requires the active matching run.", call. = FALSE)
    }

    delete_ids <- unique(c(state$activity_owned, desired_order))
    delete_ids <- delete_ids[vapply(delete_ids, function(surface_id) {
      surface <- get0(surface_id, envir = state$surfaces, inherits = FALSE)
      !is.null(surface) && !isTRUE(surface$deleted)
    }, logical(1))]
    deletes <- lapply(delete_ids, function(surface_id) list(
      version = "v0.9.1", deleteSurface = list(surfaceId = surface_id)
    ))
    creates <- unlist(lapply(desired_order, function(surface_id) desired[[surface_id]]), recursive = FALSE)
    projected <- c(deletes, creates)
    if (length(projected) > 64L) {
      stop("Projected AG-UI activity exceeds 64 A2UI operations.", call. = FALSE)
    }

    if (length(projected)) {
      envelope <- send(
        thread_id, run_id, projected,
        event_id = event_id, sequence = sequence
      )
    } else {
      if (!is.null(sequence)) {
        stop("AG-UI activity sequence requires projected A2UI operations.", call. = FALSE)
      }
      envelope <- NULL
    }
    state$activity_buckets <- candidate_buckets
    state$activity_bucket_order <- candidate_order
    state$activity_owned <- desired_order
    commit_activity_event(envelope)
    invisible(envelope)
  }

  recover <- function(request) {
    request_thread <- if (is.list(request) && .a2ui_id(request$threadId)) request$threadId else "invalid"
    fail <- function(reason) {
      session$sendCustomMessage(paste0(input_id, ":a2ui-recovery-failed"), list(
        threadId = request_thread, reason = reason
      ))
      invisible(FALSE)
    }
    if (!is.list(request) || !identical(request$transportVersion, 1L) ||
        !.a2ui_id(request$threadId)) return(fail("Malformed recovery request."))
    state <- get0(request$threadId, envir = threads, inherits = FALSE)
    if (is.null(state)) return(fail("Unknown A2UI recovery thread."))
    from <- suppressWarnings(as.numeric(request$expectedSequence))
    to <- suppressWarnings(as.numeric(request$receivedSequence))
    if (length(from) != 1L || length(to) != 1L || !is.finite(from) || !is.finite(to) ||
        abs(from) > 2^53 - 1 || abs(to) > 2^53 - 1 || from %% 1 != 0 || to %% 1 != 0 ||
        from < 1 || to < from || to - from + 1 > 64L) return(fail("Invalid recovery range."))
    wanted <- seq.int(from, to)
    by_sequence <- setNames(state$ledger, vapply(state$ledger, function(entry) as.character(entry$sequence), ""))
    entries <- unname(by_sequence[as.character(wanted)])
    if (length(entries) != length(wanted) || any(vapply(entries, is.null, logical(1)))) {
      return(fail("Authoritative A2UI recovery ledger is incomplete."))
    }
    if (!identical(entries[[length(entries)]]$eventId, request$eventId)) {
      return(fail("Recovery terminal event does not match."))
    }
    session$sendCustomMessage(paste0(input_id, ":a2ui-recovery"), list(
      transportVersion = 1L, threadId = request$threadId,
      fromSequence = from, toSequence = to,
      envelopes = lapply(entries, `[[`, "envelope")
    ))
    invisible(TRUE)
  }

  restore_authority <- function(thread_id, messages, cp) {
    if (!is.list(cp) || !.a2ui_exact_names(cp, c(
          "transportVersion", "protocolVersion", "schemaVersion", "lastAcceptedSequence",
          "generation", "eventLedger", "lineage"
        )) || !identical(cp$transportVersion, 1L) ||
        !identical(cp$protocolVersion, "v0.9") || !identical(cp$schemaVersion, 1L) ||
        !is.numeric(cp$lastAcceptedSequence) || length(cp$lastAcceptedSequence) != 1L ||
        !is.finite(cp$lastAcceptedSequence) || cp$lastAcceptedSequence < 0 || cp$lastAcceptedSequence %% 1 != 0 ||
        !is.numeric(cp$generation) || length(cp$generation) != 1L || !is.finite(cp$generation) ||
        cp$generation < 0 || cp$generation %% 1 != 0 || !is.list(cp$lineage) ||
        !all(vapply(cp$lineage, function(entry) {
          is.list(entry) && .a2ui_exact_names(
            entry, c("surfaceId", "epoch", "revision", "deletedAtSequence"),
            c("surfaceId", "epoch", "revision")
          ) && .a2ui_id(entry$surfaceId) && is.numeric(entry$epoch) && is.numeric(entry$revision) &&
            entry$epoch > 0 && entry$epoch <= entry$revision && entry$revision <= cp$lastAcceptedSequence &&
            (is.null(entry$deletedAtSequence) || identical(as.numeric(entry$deletedAtSequence), as.numeric(entry$revision)))
        }, logical(1)))) return(invisible(FALSE))
    deleted_flags <- vapply(cp$lineage, function(entry) !is.null(entry$deletedAtSequence), logical(1))
    if (length(cp$lineage) > 144L || sum(!deleted_flags) > 16L || sum(deleted_flags) > 128L) {
      return(invisible(FALSE))
    }
    state <- thread_state(thread_id)
    next_last_sequence <- as.numeric(cp$lastAcceptedSequence %||% 0)
    next_generation <- as.numeric(cp$generation %||% 0)
    ledger <- cp$eventLedger %||% list()
    valid_ledger <- is.list(ledger) && length(ledger) <= 64L && all(vapply(ledger, function(entry) {
      is.list(entry) && .a2ui_id(entry$eventId) && is.numeric(entry$sequence) &&
        length(entry$sequence) == 1L && entry$sequence > 0 && entry$sequence <= next_last_sequence &&
        is.character(entry$digest) && length(entry$digest) == 1L && grepl("^[0-9a-f]{64}$", entry$digest)
    }, logical(1)))
    if (!valid_ledger) return(invisible(FALSE))
    next_ledger <- lapply(ledger, function(entry) c(entry, list(envelope = NULL)))
    next_events <- new.env(hash = TRUE, parent = emptyenv())
    for (entry in next_ledger) assign(entry$eventId, entry, envir = next_events)
    next_surfaces <- new.env(hash = TRUE, parent = emptyenv())
    for (entry in cp$lineage) {
      if (!is.list(entry) || !.a2ui_id(entry$surfaceId)) next
      deleted <- !is.null(entry$deletedAtSequence)
      assign(entry$surfaceId, list(
        surfaceId = entry$surfaceId, epoch = as.numeric(entry$epoch), revision = as.numeric(entry$revision),
        deleted = deleted, deletedAtSequence = entry$deletedAtSequence,
        components = list(), actions = list(), dataModel = list(), runId = "history"
      ), envir = next_surfaces)
    }
    seen_live <- character()
    for (message in messages %||% list()) for (part in message$content %||% list()) {
      candidate <- .a2ui_part_candidate(part)
      marker <- .a2ui_marker_from_part(part)
      if (is.null(marker)) {
        if (candidate) return(invisible(FALSE))
        next
      }
      if (!.a2ui_valid_marker(part)) return(invisible(FALSE))
      surface <- get0(marker$surfaceId, envir = next_surfaces, inherits = FALSE)
      if (is.null(surface)) return(invisible(FALSE))
      if (isTRUE(surface$deleted)) {
        if (marker$revision <= surface$deletedAtSequence) next
        return(invisible(FALSE))
      }
      if (surface$epoch != marker$epoch || surface$revision != marker$revision) return(invisible(FALSE))
      for (operation in marker$snapshot) {
        if (identical(.a2ui_operation_kind(operation), "updateComponents")) {
          payload <- operation$updateComponents
          surface$components <- payload$components %||% list()
          surface$actions <- .a2ui_component_actions(surface$components)
        } else if (identical(.a2ui_operation_kind(operation), "updateDataModel")) {
          payload <- operation$updateDataModel
          value_name <- intersect(c("contents", "value", "data"), names(payload))[[1L]]
          surface$dataModel <- .a2ui_pointer_set(
            surface$dataModel, payload$path %||% "/", payload[[value_name]]
          )
        }
      }
      assign(marker$surfaceId, surface, envir = next_surfaces)
      seen_live <- union(seen_live, marker$surfaceId)
    }
    live_ids <- vapply(cp$lineage[vapply(cp$lineage, function(entry) is.null(entry$deletedAtSequence), logical(1))],
                       function(entry) entry$surfaceId, "")
    if (!all(live_ids %in% seen_live)) return(invisible(FALSE))
    state$last_sequence <- next_last_sequence
    state$generation <- next_generation
    state$ledger <- next_ledger
    state$events <- next_events
    state$surfaces <- next_surfaces
    state$activity_buckets <- list()
    state$activity_bucket_order <- character()
    state$activity_owned <- character()
    state$activity_events <- new.env(hash = TRUE, parent = emptyenv())
    state$activity_event_order <- character()
    invisible(TRUE)
  }

  handle_action <- function(message) {
    settled <- FALSE
    action_id <- if (is.list(message)) message$actionId %||% NULL else NULL
    reject <- function(reason) {
      if (settled) return(invisible(FALSE))
      settled <<- TRUE
      session$sendCustomMessage(paste0(input_id, ":a2ui-action-result"), list(
        actionId = action_id, threadId = if (is.list(message)) message$threadId %||% NULL else NULL,
        status = "error", message = reason
      ))
      invisible(FALSE)
    }
    allowed <- c(
      "transportVersion", "actionId", "threadId", "surfaceId",
      "sourceComponentId", "name", "epoch", "revision", "input", "context", "ts"
    )
    if (!is.function(action_handler) || !is.list(message) ||
        any(!names(message) %in% allowed) || !identical(message$transportVersion, 1L) ||
        !.a2ui_id(message$actionId) || !.a2ui_id(message$threadId) || !.a2ui_id(message$surfaceId) ||
        !.a2ui_id(message$sourceComponentId) || !is.character(message$name) || length(message$name) != 1L ||
        !is.numeric(message$epoch) || length(message$epoch) != 1L || !is.finite(message$epoch) ||
        message$epoch <= 0 || message$epoch %% 1 != 0 ||
        !is.numeric(message$revision) || length(message$revision) != 1L || !is.finite(message$revision) ||
        message$revision <= 0 || message$revision %% 1 != 0 ||
        !grepl("^[A-Za-z][A-Za-z0-9_.:-]{0,127}$", message$name) ||
        !.a2ui_json_safe(message$input) || !.a2ui_json_safe(message$context)) {
      return(reject("Invalid or unsupported A2UI action."))
    }
    action_bytes <- nchar(as.character(jsonlite::toJSON(
      message[c("input", "context")], auto_unbox = TRUE, null = "null", digits = NA
    )), type = "bytes")
    if (action_bytes > 64L * 1024L) return(reject("A2UI action payload is too large."))
    cutoff <- now() - 600
    replay_names <- ls(action_replay, all.names = TRUE)
    if (length(replay_names)) {
      stale_names <- replay_names[vapply(replay_names, function(key) {
        get(key, envir = action_replay, inherits = FALSE) < cutoff
      }, logical(1))]
      if (length(stale_names)) rm(list = stale_names, envir = action_replay)
    }
    replay_key <- paste(ui_owner, message$threadId, message$surfaceId, message$actionId, sep = "\u001f")
    if (exists(replay_key, envir = action_replay, inherits = FALSE)) return(reject("Duplicate A2UI action."))
    state <- get0(message$threadId, envir = threads, inherits = FALSE)
    if (is.null(state)) return(reject("Stale or unauthorized A2UI action."))
    surface <- get0(message$surfaceId, envir = state$surfaces, inherits = FALSE)
    action <- if (is.null(surface)) NULL else surface$actions[[message$sourceComponentId]]
    if (is.null(surface) || isTRUE(surface$deleted) || surface$epoch != message$epoch ||
        surface$revision != message$revision || is.null(action) ||
        !identical(action$name, message$name)) {
      return(reject("Stale or unauthorized A2UI action."))
    }
    projected_context <- .a2ui_project_action_context(action$context, message$context)
    if (!isTRUE(projected_context$ok)) {
      return(reject("A2UI action context does not match its declaration."))
    }
    rate_key <- paste(ui_owner, message$threadId, message$surfaceId, sep = "\u001f")
    recent <- get0(rate_key, envir = action_times, inherits = FALSE) %||% numeric()
    recent <- recent[recent >= now() - 10]
    if (length(recent) >= 20L) return(reject("A2UI action rate limit exceeded."))
    assign(rate_key, c(recent, now()), envir = action_times)
    replay_names <- ls(action_replay, all.names = TRUE)
    if (length(replay_names) >= 256L) {
      replay_times <- vapply(replay_names, function(key) get(key, envir = action_replay), numeric(1))
      rm(list = replay_names[order(replay_times)][seq_len(length(replay_names) - 255L)],
         envir = action_replay)
    }
    assign(replay_key, now(), envir = action_replay)
    on_error <- function(reason) reject(as.character(reason)[[1L]])
    on_a2ui <- function(operations, event_id = NULL, sequence = NULL) {
      send(message$threadId, surface$runId %||% "action", operations, event_id, sequence)
    }
    succeed <- function(value = NULL) {
      if (settled) return(invisible(FALSE))
      settled <<- TRUE
      session$sendCustomMessage(paste0(input_id, ":a2ui-action-result"), list(
        actionId = message$actionId, threadId = message$threadId, status = "ok"
      ))
      invisible(TRUE)
    }
    result <- tryCatch(
      .call_compatible_callback(action_handler, list(
        name = message$name, input = message$input,
        context = projected_context$value,
        thread_id = message$threadId, surface_id = message$surfaceId,
        source_component_id = message$sourceComponentId,
        on_a2ui = on_a2ui, on_error = on_error
      )),
      error = function(error) structure(list(error = error), class = "a2ui_handler_error")
    )
    if (inherits(result, "a2ui_handler_error")) return(reject("A2UI action handler failed."))
    if (inherits(result, "promise")) {
      promises::then(
        result,
        onFulfilled = succeed,
        onRejected = function(error) reject("A2UI action handler failed.")
      )
      return(invisible(TRUE))
    }
    succeed(result)
  }

  list(
    send = send, send_activity = send_activity,
    recover = recover, checkpoint = checkpoint,
    restore_authority = restore_authority, handle_action = handle_action,
    has_surface = function(thread_id, surface_id) {
      state <- get0(thread_id, envir = threads, inherits = FALSE)
      if (is.null(state)) return(FALSE)
      surface <- get0(surface_id, envir = state$surfaces, inherits = FALSE)
      !is.null(surface) && !isTRUE(surface$deleted)
    },
    snapshot = function(thread_id) thread_state(thread_id)
  )
}
