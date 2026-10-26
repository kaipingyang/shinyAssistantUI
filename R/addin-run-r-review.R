# Plan 163 — review run_r output before it is returned to Claude.
#
# The run_r MCP subprocess (inst/mcp/run_r_server.R) executes code in the main R
# session, then asks this Background Job (over a nanonext REQ/REP endpoint) whether
# the formatted result may be returned. The browser shows the pending output; the
# user sends it, sends an edited version, or declines. Every failure path declines:
# Claude never receives output the user has not approved. Review controls what is
# returned, not what runs — execution approval is unchanged.

.RUN_R_REVIEW_MAX_TEXT <- 200000L
.RUN_R_REVIEW_DECISIONS <- c("approve", "edit", "reject")

# ── Toggle (own file, so older installed versions keep reading settings v2) ───
.run_r_output_review_path <- function(home = Sys.getenv("HOME", unset = "~")) {
  .claude_addin_path("run_r_output_review.json", home)
}

# Missing, unreadable, malformed or unsafe state means "review on" (fail closed).
.run_r_output_review_path_safe <- function(path) {
  if (!file.exists(path)) return(TRUE)
  link <- tryCatch(Sys.readlink(path), error = function(e) NA_character_)
  info <- tryCatch(file.info(path), error = function(e) NULL)
  !is.na(link) && !nzchar(link) && !is.null(info) && isFALSE(info$isdir[[1L]])
}

.read_run_r_output_review_enabled <- function(path = .run_r_output_review_path()) {
  if (!file.exists(path) || !.run_r_output_review_path_safe(path)) return(TRUE)
  raw <- tryCatch(.read_strict_json_file(path, max_bytes = 1024L), error = function(e) NULL)
  value <- if (is.list(raw) && identical(raw$classification, "valid")) raw$value else NULL
  if (!is.list(value) || !identical(names(value), "enabled")) return(TRUE)
  enabled <- value$enabled
  if (is.logical(enabled) && length(enabled) == 1L && !is.na(enabled)) enabled else TRUE
}

.write_run_r_output_review_enabled <- function(enabled,
                                               path = .run_r_output_review_path()) {
  if (!is.logical(enabled) || length(enabled) != 1L || is.na(enabled)) return(FALSE)
  if (!.run_r_output_review_path_safe(path)) return(FALSE)
  ok <- tryCatch({
    dir <- dirname(path)
    if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, mode = "0700")
    tmp <- tempfile(".run_r_output_review-", tmpdir = dir, fileext = ".json")
    on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
    writeLines(if (enabled) '{"enabled":true}' else '{"enabled":false}', tmp)
    Sys.chmod(tmp, mode = "0600", use_umask = FALSE)
    file.rename(tmp, path) && identical(.read_run_r_output_review_enabled(path), enabled)
  }, error = function(e) FALSE)
  isTRUE(ok)
}

# ── Review service (pure; no Shiny or sockets) ─────────────────────────────────
.run_r_review_scalar <- function(value) {
  is.character(value) && length(value) == 1L && !is.na(value)
}

.RUN_R_REVIEW_REQUEST_KEYS <- c("type", "version", "request_id", "thread_id", "code",
                                "text", "is_error")

.valid_run_r_review_request <- function(req) {
  is.list(req) && setequal(names(req), .RUN_R_REVIEW_REQUEST_KEYS) &&
    length(names(req)) == length(.RUN_R_REVIEW_REQUEST_KEYS) &&
    identical(req$type, "run_r_output_review") &&
    is.numeric(req$version) && length(req$version) == 1L && identical(as.numeric(req$version), 1) &&
    .run_r_review_scalar(req$request_id) && nzchar(req$request_id) &&
    .run_r_review_scalar(req$thread_id) && nzchar(req$thread_id) &&
    .run_r_review_scalar(req$code) && .run_r_review_scalar(req$text) &&
    is.logical(req$is_error) && length(req$is_error) == 1L && !is.na(req$is_error)
}

.new_run_r_review_service <- function(
    enabled = function() TRUE,
    timeout = 600,
    schedule = function(callback, delay) {
      timer <- later::later(callback, delay = delay)
      function() .cancel_later_timer(timer)
    },
    id_factory = function() paste0("rr-", .diagnostics_hex_token())) {
  pending <- new.env(parent = emptyenv())
  sinks <- new.env(parent = emptyenv())
  order <- character()

  safe <- function(fn, ...) tryCatch(fn(...), error = function(e) NULL)
  public_review <- function(entry) entry$review
  broadcast <- function(kind, ...) {
    for (key in ls(sinks, all.names = TRUE)) {
      sink <- get0(key, envir = sinks, inherits = FALSE)
      if (!is.null(sink)) safe(sink[[kind]], ...)
    }
  }
  finish <- function(id, decision, text = NULL, reason = NULL) {
    entry <- get0(id, envir = pending, inherits = FALSE)
    if (is.null(entry)) return(FALSE)
    rm(list = id, envir = pending)
    order <<- setdiff(order, id)
    safe(entry$cancel_timer)
    response <- list(decision = decision, request_id = entry$request_id)
    if (!is.null(text)) response$text <- text
    if (!is.null(reason)) response$reason <- reason
    safe(entry$respond, response)
    broadcast("dismiss", id, decision)
    TRUE
  }
  reject_now <- function(respond, reason, request_id = NULL) {
    safe(respond, list(decision = "reject", reason = reason, request_id = request_id))
    invisible(FALSE)
  }

  request <- function(req, respond) {
    if (!.valid_run_r_review_request(req)) return(reject_now(respond, "invalid_request"))
    # Only an explicit FALSE skips review; errors and odd values keep it on.
    on <- !identical(tryCatch(enabled(), error = function(e) TRUE), FALSE)
    if (!on) {
      safe(respond, list(decision = "approve", text = req$text, request_id = req$request_id))
      return(invisible(TRUE))
    }
    if (!length(ls(sinks, all.names = TRUE))) {
      return(reject_now(respond, "no_reviewer", req$request_id))
    }
    id <- as.character(id_factory())[[1L]]
    review <- list(
      id = id, threadId = req$thread_id, code = req$code, text = req$text,
      isError = isTRUE(req$is_error),
      expiresAt = as.numeric(Sys.time()) * 1000 + timeout * 1000
    )
    entry <- list(review = review, respond = respond, cancel_timer = NULL,
                  request_id = req$request_id)
    assign(id, entry, envir = pending)
    order <<- c(order, id)
    cancel_timer <- safe(schedule, function() finish(id, "reject", reason = "timeout"), timeout)
    if (exists(id, envir = pending, inherits = FALSE)) {
      entry$cancel_timer <- cancel_timer
      assign(id, entry, envir = pending)
    }
    broadcast("show", review)
    invisible(TRUE)
  }

  decide <- function(id, decision, text = NULL) {
    if (!.run_r_review_scalar(id) || !.run_r_review_scalar(decision) ||
        !decision %in% .RUN_R_REVIEW_DECISIONS) return(FALSE)
    entry <- get0(id, envir = pending, inherits = FALSE)
    if (is.null(entry)) return(FALSE)
    if (identical(decision, "approve")) return(finish(id, "approve", text = entry$review$text))
    if (identical(decision, "reject")) return(finish(id, "reject", reason = "user"))
    if (!.run_r_review_scalar(text) || nchar(text, type = "chars") > .RUN_R_REVIEW_MAX_TEXT) {
      return(FALSE)
    }
    finish(id, "edit", text = text)
  }

  cancel_thread <- function(thread_id) {
    if (!.run_r_review_scalar(thread_id)) return(invisible(0L))
    ids <- Filter(function(id) {
      identical(get0(id, envir = pending, inherits = FALSE)$review$threadId, thread_id)
    }, order)
    for (id in ids) finish(id, "reject", reason = "stopped")
    invisible(length(ids))
  }

  add_sink <- function(key, show, dismiss) {
    assign(key, list(show = show, dismiss = dismiss), envir = sinks)
    for (id in order) {
      entry <- get0(id, envir = pending, inherits = FALSE)
      if (!is.null(entry)) safe(show, public_review(entry))
    }
    function() {
      if (exists(key, envir = sinks, inherits = FALSE)) rm(list = key, envir = sinks)
      invisible(NULL)
    }
  }

  list(
    request = request,
    decide = decide,
    cancel_thread = cancel_thread,
    add_sink = add_sink,
    pending = function() lapply(order, function(id) public_review(get(id, envir = pending))),
    close = function() {
      for (id in order) finish(id, "reject", reason = "shutdown")
      invisible(NULL)
    }
  )
}

# ── nanonext endpoint (Background Job) ─────────────────────────────────────────
# One REP context waits for the next request. When it arrives the context is kept
# for the delayed reply and a fresh context is armed, so several reviews (one per
# thread) can be pending at once without blocking the Shiny event loop.
.start_run_r_review_server <- function(url, service, poll = 0.1) {
  if (!requireNamespace("nanonext", quietly = TRUE) ||
      !requireNamespace("later", quietly = TRUE)) return(NULL)
  sock <- tryCatch(nanonext::socket("rep", listen = url), error = function(e) NULL)
  if (is.null(sock)) return(NULL)
  state <- new.env(parent = emptyenv())
  state$active <- TRUE
  # Context creation and receive are armed together; any failure leaves no
  # half-armed state behind.
  arm <- function() {
    armed <- tryCatch({
      ctx <- nanonext::context(sock)
      list(ctx = ctx, aio = nanonext::recv_aio(ctx, mode = "serial"))
    }, error = function(e) NULL)
    if (is.null(armed)) return(FALSE)
    state$ctx <- armed$ctx
    state$aio <- armed$aio
    TRUE
  }
  # Each reply is bound to the context its request arrived on (frozen per call;
  # a shared loop variable would let concurrent requests receive each other's
  # decisions).
  responder_for <- function(ctx) {
    force(ctx)
    function(response) {
      tryCatch(nanonext::send(ctx, response, mode = "serial", block = 1000),
               error = function(e) NULL)
    }
  }
  if (!arm()) {
    try(close(sock), silent = TRUE)
    return(NULL)
  }
  shutdown <- function() {
    if (!isTRUE(state$active)) return(invisible(FALSE))
    state$active <- FALSE
    service$close()
    try(close(sock), silent = TRUE)
    invisible(TRUE)
  }
  service_loop <- function() {
    if (!isTRUE(state$active)) return(invisible(NULL))
    delay <- poll
    while (isTRUE(state$active) &&
           !isTRUE(tryCatch(nanonext::unresolved(state$aio), error = function(e) FALSE))) {
      data <- state$aio$data
      respond <- responder_for(state$ctx)
      if (nanonext::is_error_value(data)) {
        # Receive failed (e.g. socket closing): re-arm once and back off instead of
        # spinning on immediately-failing receives.
        if (!arm()) shutdown()
        delay <- max(poll, 1)
        break
      }
      if (!arm()) {
        respond(list(decision = "reject", reason = "unavailable"))
        shutdown()
        break
      }
      service$request(data, respond)
    }
    if (isTRUE(state$active)) later::later(service_loop, delay)
    invisible(NULL)
  }
  later::later(service_loop, poll)
  list(url = url, close = shutdown)
}

# Environment for the run_r MCP subprocess: where to ask for review.
.addin_run_r_review_env <- function(server_config, review_url, timeout_seconds = 600) {
  if (!is.list(server_config) || !.run_r_review_scalar(review_url) || !nzchar(review_url)) {
    return(server_config)
  }
  server_config$env$CLAUDE_ADDIN_REVIEW_URL <- review_url
  # Leave the subprocess a little longer than the service timeout so the service,
  # not the socket, decides the outcome.
  server_config$env$CLAUDE_ADDIN_REVIEW_TIMEOUT_MS <- as.character(
    as.integer((timeout_seconds + 30) * 1000)
  )
  server_config
}

# ── Shiny session binding ──────────────────────────────────────────────────────
.bind_run_r_review <- function(service, session, input_id,
                               read_enabled = .read_run_r_output_review_enabled,
                               write_enabled = .write_run_r_output_review_enabled,
                               on_enabled_changed = NULL,
                               send = NULL) {
  key <- paste0("session-", .diagnostics_hex_token())
  message_type <- paste0(input_id, ":run-r-review")
  if (!is.function(send)) send <- function(payload) {
    tryCatch(session$sendCustomMessage(message_type, payload), error = function(e) NULL)
  }
  remove_sink <- service$add_sink(
    key,
    show = function(review) send(list(type = "show", review = review)),
    dismiss = function(id, outcome) send(list(type = "dismiss", id = id, outcome = outcome))
  )
  session$onSessionEnded(function() remove_sink())

  shiny::observeEvent(session$input[[paste0(input_id, "_run_r_review")]], {
    msg <- session$input[[paste0(input_id, "_run_r_review")]]
    if (!is.list(msg)) return()
    if (identical(msg$type, "sync")) {
      # The browser asks once its handler is registered: messages sent while the
      # page was still loading (e.g. after a reload) may have been dropped.
      for (review in service$pending()) send(list(type = "show", review = review))
      send(list(type = "settings", enabled = isTRUE(read_enabled())))
    } else if (identical(msg$type, "decide")) {
      service$decide(msg$id, msg$decision, msg$text)
    } else if (identical(msg$type, "set_enabled") && is.logical(msg$enabled) &&
               length(msg$enabled) == 1L && !is.na(msg$enabled)) {
      if (isTRUE(write_enabled(msg$enabled)) && is.function(on_enabled_changed)) {
        tryCatch(on_enabled_changed(msg$enabled), error = function(e) NULL)
      }
      send(list(type = "settings", enabled = isTRUE(read_enabled())))
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # Stop declines this thread's pending reviews (Claude has stopped waiting).
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    thread_id <- if (is.list(msg)) msg$threadId else NULL
    if (.run_r_review_scalar(thread_id)) service$cancel_thread(thread_id)
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  list(
    config = list(version = 1L, enabled = isTRUE(read_enabled())),
    broadcast_enabled = function(enabled) send(list(type = "settings", enabled = isTRUE(enabled)))
  )
}
