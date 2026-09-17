.diagnostics_settings_safe_id <- function(value, positive = TRUE) {
  .settings_safe_integer(value, positive = positive)
}

.settings_wire_categories <- c(
  "ok", "busy", "malformed_document", "migration_recovery_pending",
  "stale_owner", "duplicate_request", "out_of_order", "stale_revision",
  "revision_exhausted", "io_error", "readback_mismatch", "unsupported"
)

.settings_wire_request <- function(message) {
  if (!is.list(message) || !identical(names(message), c(
    "version", "kind", "field", "ownerId", "requestId", "expectedRevision", "value"
  )) || !identical(message$version, 2L) ||
      !identical(message$kind, "settings_request") ||
      !.diagnostics_scalar_character(message$field) ||
      !message$field %in% .addin_settings_fields() ||
      is.null(.settings_safe_integer(message$ownerId, TRUE)) ||
      is.null(.settings_safe_integer(message$requestId, TRUE)) ||
      is.null(.settings_safe_integer(message$expectedRevision)) ||
      is.null(.addin_setting_value(message$field, message$value, FALSE))) return(NULL)
  message
}

.settings_wire_fingerprint <- function(message) {
  serialize(message[c("field", "ownerId", "requestId", "expectedRevision", "value")],
            NULL, version = 2L)
}

.new_addin_settings_coordinator <- function(
    document = .read_addin_settings_document(), path = .addin_settings_path(),
    transact = function(field, expected_revision, value) {
      .transact_addin_setting(field, expected_revision, value, path)
    },
    on_confirmed = function(field, value, transaction) invisible(NULL),
    schedule = function(callback) {
      if (!requireNamespace("later", quietly = TRUE)) { callback(); return(NULL) }
      timer <- later::later(callback, delay = 0)
      function() .cancel_later_timer(timer)
    }) {
  if (!is.list(document) || !document$classification %in% c("missing", "valid")) {
    document <- list(settings = .read_addin_settings(path),
                     revisions = setNames(as.list(rep(0, 9)), .addin_settings_fields()))
  }
  state <- new.env(parent = emptyenv())
  state$disposed <- FALSE
  state$values <- document$settings
  state$revisions <- document$revisions
  state$owner_allocator <- 0
  state$serial <- 0L
  state$bindings <- new.env(hash = TRUE, parent = emptyenv())

  field_wire <- function(field) list(
    value = state$values[[field]], revision = state$revisions[[field]]
  )
  fields_wire <- function() setNames(lapply(.addin_settings_fields(), field_wire),
                                     .addin_settings_fields())

  send <- function(binding, suffix, message) {
    if (state$disposed || is.null(binding) || binding$disposed || is.null(binding$session))
      return(FALSE)
    tryCatch({
      binding$session$sendCustomMessage(paste0(binding$input_id, suffix), message)
      TRUE
    }, error = function(e) FALSE)
  }
  send_result <- function(binding, request, category) {
    if (!category %in% .settings_wire_categories) category <- "unsupported"
    send(binding, ":diagnostics-settings-result", list(
      version = 2L, kind = "settings_result", field = request$field,
      ownerId = request$ownerId, requestId = request$requestId,
      revision = state$revisions[[request$field]],
      ok = identical(category, "ok"), category = category,
      value = state$values[[request$field]]
    ))
  }
  broadcast <- function(field) {
    message <- list(
      version = 2L, kind = "settings_canonical", field = field,
      revision = state$revisions[[field]], value = state$values[[field]]
    )
    for (key in ls(state$bindings, all.names = TRUE))
      send(get0(key, envir = state$bindings, inherits = FALSE),
           ":diagnostics-settings-canonical", message)
    invisible(TRUE)
  }

  process_next <- function(binding) {
    binding$armed <- FALSE
    if (state$disposed || binding$disposed || !length(binding$queue)) return(invisible(FALSE))
    request <- binding$queue[[1L]]
    binding$queue <- binding$queue[-1L]
    tx <- tryCatch(transact(
      request$field, request$expectedRevision, request$value
    ), error = function(e) list(category = "io_error", ok = FALSE))
    category <- as.character(tx$category %||% "io_error")[[1L]]
    if (!category %in% .settings_wire_categories) category <- "io_error"
    if (isTRUE(tx$ok) && identical(category, "ok")) {
      state$values[[request$field]] <- tx$value
      state$revisions[[request$field]] <- tx$revision
      tryCatch(
        on_confirmed(request$field, tx$value, tx),
        error = function(error) NULL
      )
      broadcast(request$field)
    } else if (category %in% c("stale_revision", "readback_mismatch") &&
               !is.null(tx$value) && !is.null(.settings_safe_integer(tx$revision))) {
      state$values[[request$field]] <- tx$value
      state$revisions[[request$field]] <- tx$revision
      broadcast(request$field)
    }
    send_result(binding, request, category)
    if (length(binding$queue)) arm(binding)
    invisible(TRUE)
  }
  arm <- function(binding) {
    if (binding$armed || binding$disposed || !length(binding$queue)) return(invisible(FALSE))
    binding$armed <- TRUE
    binding$cancel <- tryCatch(schedule(function() process_next(binding)), error = function(e) NULL)
    invisible(TRUE)
  }

  dispose_binding <- function(key) {
    binding <- get0(key, envir = state$bindings, inherits = FALSE)
    if (is.null(binding) || binding$disposed) return(FALSE)
    binding$disposed <- TRUE
    if (is.function(binding$cancel)) tryCatch(binding$cancel(), error = function(e) NULL)
    if (!is.null(binding$ready_observer)) tryCatch(binding$ready_observer$destroy(), error = function(e) NULL)
    if (!is.null(binding$observer)) tryCatch(binding$observer$destroy(), error = function(e) NULL)
    binding$queue <- list(); binding$session <- NULL
    rm(list = key, envir = state$bindings)
    TRUE
  }

  bind <- function(session, input_id) {
    if (state$disposed || is.null(session) || !.diagnostics_scalar_character(input_id) ||
        state$owner_allocator >= 2^53 - 1) return(NULL)
    state$owner_allocator <- state$owner_allocator + 1
    state$serial <- state$serial + 1L
    key <- paste0("binding-", state$serial)
    binding <- new.env(parent = emptyenv())
    binding$session <- session; binding$input_id <- input_id
    binding$owner_id <- state$owner_allocator; binding$last_request_id <- 0
    binding$last_fingerprint <- NULL; binding$queue <- list(); binding$armed <- FALSE
    binding$cancel <- NULL; binding$disposed <- FALSE
    binding$ready <- FALSE; binding$ready_observer <- NULL; binding$observer <- NULL
    assign(key, binding, envir = state$bindings)
    binding_config <- function() list(
      version = 2L, kind = "settings_bind", ownerSeed = binding$owner_id,
      ownerId = binding$owner_id, fields = fields_wire()
    )
    config <- binding_config()
    binding$ready_observer <- shiny::observeEvent(
      session$input[[paste0(input_id, "_diagnostics_settings_ready")]],
      {
        ready <- session$input[[paste0(input_id, "_diagnostics_settings_ready")]]
        owner_id <- if (is.list(ready)) {
          .settings_safe_integer(ready$ownerId, positive = TRUE)
        } else NULL
        if (!is.list(ready) ||
            !identical(names(ready), c("version", "kind", "ownerId")) ||
            !identical(ready$version, 2L) ||
            !identical(ready$kind, "settings_ready") ||
            is.null(owner_id) || owner_id != binding$owner_id) return()
        if (!binding$ready) {
          binding$ready <- TRUE
          return()
        }
        if (state$owner_allocator >= 2^53 - 1) return()
        if (is.function(binding$cancel)) {
          tryCatch(binding$cancel(), error = function(e) NULL)
        }
        binding$queue <- list()
        binding$armed <- FALSE
        binding$cancel <- NULL
        state$owner_allocator <- state$owner_allocator + 1
        binding$owner_id <- state$owner_allocator
        binding$last_request_id <- 0
        binding$last_fingerprint <- NULL
        binding$ready <- FALSE
        send(binding, ":diagnostics-settings-bind", binding_config())
      }, ignoreNULL = TRUE, ignoreInit = TRUE, domain = session
    )
    binding$observer <- shiny::observeEvent(
      session$input[[paste0(input_id, "_diagnostics_setting")]],
      {
        if (!binding$ready) return()
        request <- .settings_wire_request(
          session$input[[paste0(input_id, "_diagnostics_setting")]]
        )
        if (is.null(request)) return()
        if (request$ownerId != binding$owner_id) {
          send_result(binding, request, "stale_owner"); return()
        }
        fingerprint <- .settings_wire_fingerprint(request)
        if (request$requestId == binding$last_request_id) {
          if (identical(fingerprint, binding$last_fingerprint))
            send_result(binding, request, "duplicate_request")
          return()
        }
        if (request$requestId < binding$last_request_id) {
          send_result(binding, request, "out_of_order"); return()
        }
        binding$last_request_id <- request$requestId
        binding$last_fingerprint <- fingerprint
        if (length(binding$queue) >= 9L) {
          send_result(binding, request, "busy"); return()
        }
        binding$queue[[length(binding$queue) + 1L]] <- request
        arm(binding)
      }, ignoreNULL = TRUE, ignoreInit = TRUE, domain = session
    )
    session$onSessionEnded(function() dispose_binding(key))
    list(config = config, unbind = function() dispose_binding(key))
  }

  dispose <- function() {
    if (state$disposed) return(FALSE)
    state$disposed <- TRUE
    for (key in ls(state$bindings, all.names = TRUE)) dispose_binding(key)
    TRUE
  }
  snapshot <- function() list(
    disposed = state$disposed, values = state$values, revisions = state$revisions,
    bindings = length(ls(state$bindings, all.names = TRUE)),
    last_owner = state$owner_allocator
  )
  list(
    config = function() list(version = 2L, protocol = "field-cas"),
    bind = bind, dispose = dispose, snapshot = snapshot
  )
}

# Back-compatible constructor name for the addin host. It now exposes the v2
# coordinator and both diagnostics fields rather than a diagnostics-only v1 bus.
.new_diagnostics_settings_addin_plugin <- function(
    desired = TRUE, show_performance_orb = TRUE, launch_enabled = FALSE,
    environment_override = c("none", "on", "off"),
    launch_kind = c("job", "foreground"), persist = function(value) FALSE,
    document = NULL, path = .addin_settings_path(), schedule = NULL) {
  environment_override <- match.arg(environment_override)
  launch_kind <- match.arg(launch_kind)
  if (is.null(document)) {
    settings <- .addin_settings_defaults()
    settings$diagnosticsEnabled <- isTRUE(desired)
    settings$showPerformanceOrb <- isTRUE(show_performance_orb)
    document <- list(classification = "valid", settings = settings,
                     revisions = setNames(as.list(rep(0, 9)), .addin_settings_fields()))
  }
  transaction <- function(field, expected_revision, value) {
    if (identical(field, "diagnosticsEnabled") && !identical(value, document$settings[[field]])) {
      ok <- isTRUE(tryCatch(persist(value), error = function(e) FALSE))
      if (!ok) return(list(category = "io_error", ok = FALSE,
                           value = document$settings[[field]],
                           revision = document$revisions[[field]]))
    }
    document$settings[[field]] <<- value
    document$revisions[[field]] <<- document$revisions[[field]] + 1
    list(category = "ok", ok = TRUE, value = value,
         revision = document$revisions[[field]], settings = document$settings)
  }
  args <- list(document = document, path = path, transact = transaction)
  if (is.function(schedule)) args$schedule <- schedule
  plugin <- do.call(.new_addin_settings_coordinator, args)
  base_config <- plugin$config
  plugin$config <- function() c(base_config(), list(
    launchEnabled = isTRUE(launch_enabled), environmentOverride = environment_override,
    launchKind = launch_kind
  ))
  plugin
}
