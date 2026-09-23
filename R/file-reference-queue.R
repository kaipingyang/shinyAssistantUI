.new_file_reference_queue <- function(
    resolve, deliver, on_error = function(error) warning(conditionMessage(error), call. = FALSE),
    schedule = NULL, now = function() proc.time()[["elapsed"]]) {
  if (!is.function(resolve) || !is.function(deliver) || !is.function(on_error)) {
    stop("File reference callbacks must be functions.", call. = FALSE)
  }
  if (is.null(schedule)) {
    loop <- later::current_loop()
    schedule <- function(callback, delay) later::later(callback, delay, loop = loop)
  }
  if (!is.function(schedule) || !is.function(now)) {
    stop("File reference scheduler and clock must be functions.", call. = FALSE)
  }
  closed <- FALSE
  generation <- 0L
  current <- NULL
  cancel_pending <- NULL
  cancel <- function() {
    generation <<- generation + 1L
    current <<- NULL
    handle <- cancel_pending
    cancel_pending <<- NULL
    if (!is.null(handle)) .cancel_later_timer(handle)
    invisible(NULL)
  }
  arm <- function(delay) {
    if (closed || is.null(current)) return(invisible(NULL))
    if (!is.null(cancel_pending)) stop("File reference queue already has a timer.", call. = FALSE)
    token <- generation
    cancel_pending <<- schedule(function() {
      if (closed || token != generation || is.null(current)) return(invisible(NULL))
      cancel_pending <<- NULL
      step(token)
    }, delay)
    if (!is.function(cancel_pending)) {
      cancel_pending <<- NULL
      stop("File reference scheduler must return a cancellation function.", call. = FALSE)
    }
    invisible(NULL)
  }
  step <- function(token) {
    job <- current
    started <- now()
    count <- 0L
    while (job$index <= length(job$paths)) {
      path <- job$paths[[job$index]]
      resolved <- tryCatch(resolve(path, job$request), error = function(error) {
        on_error(error)
        NULL
      })
      if (closed || token != generation || !identical(job, current)) return(invisible(NULL))
      job$files[[job$index]] <- list(path = path, resolvedPath = resolved)
      job$index <- job$index + 1L
      count <- count + 1L
      if (count >= 4L || now() - started >= 0.008) break
    }
    if (job$index > length(job$paths)) {
      current <<- NULL
      tryCatch(deliver(job$request, job$files), error = on_error)
    } else {
      # A positive delay lets Shiny service I/O, not just other due later callbacks.
      arm(0.001)
    }
    invisible(NULL)
  }
  list(
    submit = function(request) {
      if (closed) return(invisible(FALSE))
      cancel()
      job <- new.env(parent = emptyenv())
      job$request <- request
      job$paths <- unique(unlist(request$paths, use.names = FALSE))
      job$files <- vector("list", length(job$paths))
      job$index <- 1L
      current <<- job
      arm(0)
      invisible(TRUE)
    },
    close = function() {
      if (closed) return(invisible(FALSE))
      closed <<- TRUE
      cancel()
      invisible(TRUE)
    }
  )
}
