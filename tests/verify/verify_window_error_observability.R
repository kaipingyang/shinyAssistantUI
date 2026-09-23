#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(chromote))
source("tests/verify/owned_process_cleanup.R")

main <- function() {
  browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() NULL)
  on.exit(cleanup(), add = TRUE)
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- ChromoteSession$new(width = 800, height = 600)
  console_errors <- exceptions <- list()
  browser$Runtime$enable()
  browser$Page$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) {
      console_errors[[length(console_errors) + 1L]] <<- event
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    exceptions[[length(exceptions) + 1L]] <<- event
  })
  browser$Page$addScriptToEvaluateOnNewDocument(source = paste0(
    "window.errorProbe=[];window.addEventListener('error',event=>{",
    "window.errorProbe.push({category:event instanceof ErrorEvent?'script':'resource',",
    "message:event.message||'',hasErrorObject:!!event.error,",
    "hasStack:typeof event.error?.stack==='string',trusted:event.isTrusted,",
    "line:event.lineno||0,column:event.colno||0});});"
  ))
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait_for <- function(js) {
    deadline <- Sys.time() + 5
    repeat {
      if (isTRUE(value(js))) return(TRUE)
      if (Sys.time() > deadline) {
        cat("CONTROL_PROBE_TIMEOUT ", jsonlite::toJSON(list(
          condition = js,
          page = value("({url:location.href,ready:document.readyState,probeType:typeof window.errorProbe})"),
          exceptions = exceptions
        ), auto_unbox = TRUE, null = "null"), "\n", sep = "")
        return(FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  report <- function(name, start_console, start_exceptions) {
    result <- list(
      scenario = name,
      window_errors = value("window.errorProbe"),
      console_error_count = length(console_errors) - start_console,
      runtime_exception_count = length(exceptions) - start_exceptions
    )
    cat("ERROR_SURFACE ", jsonlite::toJSON(result, auto_unbox = TRUE, null = "null"), "\n", sep = "")
    result
  }

  browser$Page$navigate("data:text/html,<!doctype html><title>Async throw control</title>")
  stopifnot(wait_for("Array.isArray(window.errorProbe)"))
  start_console <- length(console_errors)
  start_exceptions <- length(exceptions)
  value("setTimeout(()=>{throw new Error('SYNTHETIC_ASYNC_THROW')},0);true")
  stopifnot(wait_for("window.errorProbe.some(e=>e.message.includes('SYNTHETIC_ASYNC_THROW'))"))
  thrown <- report("ordinary-async-throw", start_console, start_exceptions)
  stopifnot(
    length(thrown$window_errors) == 1L,
    identical(thrown$window_errors[[1L]]$category, "script"),
    isTRUE(thrown$window_errors[[1L]]$hasStack),
    thrown$runtime_exception_count >= 1L
  )

  browser$Page$navigate("data:text/html,<!doctype html><title>Resize observer control</title>")
  stopifnot(wait_for("Array.isArray(window.errorProbe)&&window.errorProbe.length===0"))
  start_console <- length(console_errors)
  start_exceptions <- length(exceptions)
  value(paste0(
    "(()=>{const box=document.createElement('div');",
    "box.style.cssText='width:100px;height:20px';document.body.append(box);",
    "window.resizeProbeCount=0;window.resizeProbeDone=false;",
    "const observer=new ResizeObserver(()=>{window.resizeProbeCount++;",
    "if(window.resizeProbeCount>=3){observer.disconnect();",
    "setTimeout(()=>window.resizeProbeDone=true,50);return;}",
    "box.style.width=(box.getBoundingClientRect().width+1)+'px';});",
    "observer.observe(box);return true})()"
  ))
  stopifnot(wait_for("window.resizeProbeDone===true"))
  resize <- report("bounded-native-resize-feedback", start_console, start_exceptions)
  stopifnot(
    length(resize$window_errors) >= 1L,
    all(vapply(resize$window_errors, function(event) {
      identical(event$category, "script") &&
        grepl("ResizeObserver", event$message, fixed = TRUE) &&
        isTRUE(event$trusted)
    }, logical(1))),
    identical(value("window.resizeProbeCount"), 3L)
  )
  cleanup()
  cat("WINDOW_ERROR_OBSERVABILITY_DONE intentional_controls=true cleanup=true\n")
}

main()
