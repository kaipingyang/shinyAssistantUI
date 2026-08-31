# Internal cooperative run scheduler used by assistantUIServer().
#
# Each thread owns one ExtendedTask, preserving Shiny's native FIFO semantics
# inside that thread. A package-owned permit queue bounds how many different
# thread tasks may enter backend handlers at once.

.normalize_max_concurrent_runs <- function(value, ceiling = 8L) {
  if (length(value) != 1L || is.na(value) || !is.numeric(value) ||
      value != as.integer(value) || value < 1L) {
    stop("`max_concurrent_runs` must be one positive integer.", call. = FALSE)
  }
  min(as.integer(value), as.integer(ceiling))
}

.effective_max_concurrent_runs <- function(handler, requested, ceiling = 8L) {
  requested <- .normalize_max_concurrent_runs(requested, ceiling)
  if (isTRUE(attr(handler, "supports_concurrent_threads"))) requested else 1L
}

.new_thread_run_scheduler <- function(run, max_concurrent = 1L,
                                      on_state = function(...) NULL,
                                      on_cancelled_settled = function(...) NULL,
                                      task_factory = function(fn) shiny::ExtendedTask$new(fn)) {
  stopifnot(is.function(run), is.function(on_state),
            is.function(on_cancelled_settled), is.function(task_factory))
  max_concurrent <- .normalize_max_concurrent_runs(max_concurrent)

  tasks <- new.env(parent = emptyenv())
  cancelled <- new.env(parent = emptyenv())
  inflight <- new.env(parent = emptyenv())
  active_runs <- new.env(parent = emptyenv())
  latest_by_thread <- new.env(parent = emptyenv())
  waiting <- list()
  active <- 0L
  closed <- FALSE

  emit <- function(thread_id, run_id, phase, queue_position = NULL) {
    args <- list(thread_id = thread_id, run_id = run_id, phase = phase)
    if (!is.null(queue_position)) args$queue_position <- as.integer(queue_position)
    tryCatch(do.call(on_state, args), error = function(e) NULL)
    invisible(NULL)
  }

  update_positions <- function() {
    if (!length(waiting)) return(invisible(NULL))
    for (i in seq_along(waiting)) {
      request <- waiting[[i]]
      emit(request$thread_id, request$run_id, "queued", i)
    }
    invisible(NULL)
  }

  release_permit <- function(run_id) {
    if (exists(run_id, envir = active_runs, inherits = FALSE)) {
      rm(list = run_id, envir = active_runs)
      active <<- max(0L, active - 1L)
    }

    while (!closed && active < max_concurrent && length(waiting)) {
      request <- waiting[[1L]]
      waiting <<- waiting[-1L]
      if (isTRUE(get0(request$run_id, envir = cancelled, inherits = FALSE,
                      ifnotfound = FALSE))) {
        request$resolve(FALSE)
        next
      }
      active <<- active + 1L
      assign(request$run_id, request$thread_id, envir = active_runs)
      request$resolve(TRUE)
    }
    update_positions()
    invisible(NULL)
  }

  acquire_permit <- function(thread_id, run_id) {
    promises::promise(function(resolve, reject) {
      if (closed || isTRUE(get0(run_id, envir = cancelled, inherits = FALSE,
                               ifnotfound = FALSE))) {
        resolve(FALSE)
        return()
      }
      if (active < max_concurrent && !length(waiting)) {
        active <<- active + 1L
        assign(run_id, thread_id, envir = active_runs)
        resolve(TRUE)
        return()
      }
      waiting <<- c(waiting, list(list(
        thread_id = thread_id, run_id = run_id, resolve = resolve
      )))
      update_positions()
    })
  }

  task_body <- coro::async(function(thread_id, run_id, ...) {
    acquired <- coro::await(acquire_permit(thread_id, run_id))
    if (!isTRUE(acquired)) {
      if (exists(run_id, envir = inflight, inherits = FALSE)) rm(list = run_id, envir = inflight)
      if (isTRUE(get0(run_id, envir = cancelled, inherits = FALSE, ifnotfound = FALSE))) {
        tryCatch(on_cancelled_settled(thread_id, run_id), error = function(e) NULL)
      }
      return(invisible(NULL))
    }
    on.exit({
      was_cancelled <- isTRUE(get0(run_id, envir = cancelled, inherits = FALSE,
                                  ifnotfound = FALSE))
      if (exists(run_id, envir = inflight, inherits = FALSE)) rm(list = run_id, envir = inflight)
      release_permit(run_id)
      if (was_cancelled) {
        tryCatch(on_cancelled_settled(thread_id, run_id), error = function(e) NULL)
      }
    }, add = TRUE)

    if (isTRUE(get0(run_id, envir = cancelled, inherits = FALSE,
                    ifnotfound = FALSE))) return(invisible(NULL))
    emit(thread_id, run_id, "connecting")
    value <- run(thread_id, run_id, ...)
    if (inherits(value, "promise")) coro::await(value)
    invisible(NULL)
  })

  get_task <- function(thread_id) {
    if (!exists(thread_id, envir = tasks, inherits = FALSE)) {
      assign(thread_id, task_factory(task_body), envir = tasks)
    }
    get(thread_id, envir = tasks, inherits = FALSE)
  }

  cancel <- function(thread_id, run_id = NULL) {
    if (is.null(run_id) || !nzchar(run_id %||% "")) {
      run_id <- get0(thread_id, envir = latest_by_thread, inherits = FALSE)
    }
    if (is.null(run_id) || !nzchar(run_id %||% "")) return(invisible(FALSE))
    assign(run_id, TRUE, envir = cancelled)

    matched <- vapply(waiting, function(request) {
      identical(request$thread_id, thread_id) && identical(request$run_id, run_id)
    }, logical(1))
    if (any(matched)) {
      requests <- waiting[matched]
      waiting <<- waiting[!matched]
      for (request in requests) request$resolve(FALSE)
      emit(thread_id, run_id, "cancelled")
      update_positions()
      return(invisible(TRUE))
    }

    if (exists(run_id, envir = active_runs, inherits = FALSE)) {
      # Active cancellation is terminal from the UI's perspective immediately,
      # while the backend keeps its permit until its cooperative cancellation
      # path actually unwinds. Later done/error callbacks are suppressed by the
      # server's per-run terminal guard.
      emit(thread_id, run_id, "cancelled")
      return(invisible(TRUE))
    }

    # A run may still be in its thread's native ExtendedTask queue and therefore
    # not yet be in the global permit queue. Marking it is enough: task_body will
    # settle it without entering the handler when it reaches the front.
    emit(thread_id, run_id, "cancelled")
    invisible(TRUE)
  }

  cancel_thread <- function(thread_id) {
    ids <- ls(inflight, all.names = TRUE)
    ids <- ids[vapply(ids, function(id) identical(get(id, envir = inflight), thread_id), logical(1))]
    for (id in ids) cancel(thread_id, id)
    invisible(ids)
  }

  close <- function() {
    if (closed) return(invisible(NULL))
    closed <<- TRUE
    if (length(waiting)) {
      requests <- waiting
      waiting <<- list()
      for (request in requests) {
        assign(request$run_id, TRUE, envir = cancelled)
        emit(request$thread_id, request$run_id, "cancelled")
        request$resolve(FALSE)
      }
    }
    ids <- ls(inflight, all.names = TRUE)
    for (id in ids) assign(id, TRUE, envir = cancelled)
    invisible(NULL)
  }

  list(
    invoke = function(thread_id, run_id, ...) {
      if (closed) return(invisible(FALSE))
      if (is.null(run_id) || !nzchar(run_id %||% "")) {
        run_id <- paste0("server-run-", as.integer(as.numeric(Sys.time()) * 1000), "-", thread_id)
      }
      thread_has_inflight <- any(vapply(
        ls(inflight, all.names = TRUE),
        function(id) identical(get(id, envir = inflight), thread_id),
        logical(1)
      ))
      must_wait <- active >= max_concurrent || length(waiting) > 0L || thread_has_inflight
      assign(run_id, thread_id, envir = inflight)
      assign(thread_id, run_id, envir = latest_by_thread)
      if (must_wait) {
        emit(thread_id, run_id, "queued", length(waiting) + 1L)
      }
      get_task(thread_id)$invoke(thread_id, run_id, ...)
      invisible(run_id)
    },
    cancel = cancel,
    cancel_thread = cancel_thread,
    close = close,
    is_busy = function() length(ls(inflight, all.names = TRUE)) > 0L,
    is_closed = function() closed,
    active_count = function() active,
    waiting_count = function() length(waiting),
    max_concurrent = max_concurrent
  )
}
