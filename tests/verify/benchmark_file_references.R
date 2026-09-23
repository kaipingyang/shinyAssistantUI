suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

run_file_reference_benchmark <- function() {
  project <- normalizePath(".")
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  installed <- normalizePath(find.package("shinyAssistantUI", lib.loc = home_lib))
  stopifnot(identical(installed, file.path(home_lib, "shinyAssistantUI")))
  repetition <- as.integer(Sys.getenv("AUI_FILE_REFERENCE_PERF_REP", "1"))
  stopifnot(repetition %in% 1:3)
  output <- Sys.getenv("AUI_FILE_REFERENCE_PERF_OUT")
  stopifnot(nzchar(output))
  dir.create(output, recursive = TRUE, showWarnings = FALSE, mode = "0700")
  output <- normalizePath(output)
  orders <- list(c("off", "shared", "slow20"), c("shared", "slow20", "off"),
                 c("slow20", "off", "shared"))
  root <- tempfile("file-reference-perf-", tmpdir = file.path(project, ".kiro"))
  dir.create(root, mode = "0700")
  root <- normalizePath(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  fixture_project <- file.path(root, "shared-files")
  dir.create(fixture_project)
  filesystem <- system2("stat", c("-f", "--format=%T", shQuote(fixture_project)), stdout = TRUE)
  stopifnot(length(filesystem) == 1L, nzchar(filesystem),
            is.null(attr(filesystem, "status")) || attr(filesystem, "status") == 0L)
  filenames <- unlist(lapply(seq.int(3L, 240L, by = 3L), function(i) {
    sprintf("file-%03d-%02d.R", i, seq_len(8L))
  }), use.names = FALSE)
  stopifnot(length(filenames) == 640L, all(file.create(file.path(fixture_project, filenames))))
  cat("FIXTURE_ROOT=", root, "\n", sep = "")
  browser_source <- paste(readLines("tests/verify/file_reference_performance.js", warn = FALSE), collapse = "\n")
  quote_js <- function(text) as.character(toJSON(text, auto_unbox = TRUE))
  summarize <- function(values) {
    values <- as.numeric(unlist(values, use.names = FALSE))
    if (!length(values)) return(list(n = 0L, median = NULL, p95 = NULL, max = NULL, total = 0))
    list(n = length(values), median = median(values),
         p95 = unname(quantile(values, 0.95)), max = max(values), total = sum(values))
  }
  run_arm <- function(arm, position) {
    enabled <- arm != "off"
    delay_ms <- if (arm == "slow20") 20 else 0
    arm_root <- file.path(root, arm)
    dir.create(arm_root)
    home <- file.path(arm_root, "home")
    dir.create(home)
    stdout <- file.path(arm_root, "app.out")
    stderr <- file.path(arm_root, "app.err")
    app <- browser <- NULL
    cleanup <- make_verification_cleanup(function() browser, function() app)
    on.exit(cleanup(), add = TRUE)
    read_log <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
    port <- httpuv::randomPort()
    app <- callr::r_bg(function(home_lib, fixture_project, port, enabled, delay_ms) {
      .libPaths(c(home_lib, .libPaths()))
      suppressPackageStartupMessages({
        library(shiny)
        library(shinyAssistantUI, lib.loc = home_lib)
      })
      stopifnot(identical(normalizePath(find.package("shinyAssistantUI")),
                          file.path(home_lib, "shinyAssistantUI")))
      clock <- function() unname(proc.time()[["elapsed"]]) * 1000
      rss <- function() shinyAssistantUI:::.read_linux_memory_snapshot(
        include_pss = FALSE, include_tree = FALSE, include_cgroup = FALSE
      )$rss_bytes / 1024^2
      history <- lapply(seq_len(240L), function(i) {
        if (i %% 3L == 1L) {
          return(list(id = paste0("bench-user-", i), role = "user",
                      content = list(list(type = "text", text = paste("Synthetic historical question", i)))))
        }
        if (i %% 3L == 2L) {
          return(list(id = paste0("bench-tool-", i), role = "assistant", content = list(list(
            type = "tool-call", toolCallId = paste0("bench-tool-call-", i), toolName = "Bash",
            args = list(command = "echo synthetic"), argsText = '{"command":"echo synthetic"}',
            result = "Synthetic historical result; nothing executed.", isError = FALSE
          )), status = list(type = "complete", reason = "stop")))
        }
        paths <- sprintf("file-%03d-%02d.R", i, seq_len(8L))
        text <- paste0(
          "Historical explanation ", i, ": these are candidate references, not file contents.\n\n",
          paste(paste0("`", c(paths, paths[[1L]]), "`"), collapse = " "),
          if (i == 240L) "\n\nBENCH_LAST_MESSAGE" else ""
        )
        list(id = paste0("bench-assistant-", i), role = "assistant",
             content = list(list(type = "text", text = text)),
             status = list(type = "complete", reason = "stop"))
      })
      ui <- bslib::page_fluid(
        tags$head(
          tags$link(rel = "icon", href = "data:,"),
          tags$style("html,body,.container-fluid{padding:0;margin:0}.bench-toolbar{height:40px;display:flex;align-items:center}")
        ),
        tags$div(class = "bench-toolbar", actionButton("advance", "Capture benchmark phase")),
        assistantUIOutput("chat", height = "calc(100vh - 40px)")
      )
      server <- function(input, output, session) {
        state <- new.env(parent = emptyenv())
        state$phase <- "idle"
        state$metrics <- list()
        state$closed <- FALSE
        state$cancel_beat <- NULL
        state$last_beat <- clock()
        begin <- function(phase) {
          state$phase <- phase
          state$last_beat <- clock()
          state$metrics[[phase]] <- list(
            started = clock(), rssBeforeMiB = rss(), heartbeatMs = numeric(),
            lookupMs = numeric(), metadataMs = numeric()
          )
        }
        heartbeat <- function() {
          if (state$closed) return(invisible(NULL))
          now <- clock()
          if (state$phase != "idle") {
            metric <- state$metrics[[state$phase]]
            metric$heartbeatMs <- c(metric$heartbeatMs, now - state$last_beat)
            state$metrics[[state$phase]] <- metric
          }
          state$last_beat <- now
          state$cancel_beat <- later::later(heartbeat, delay = 0.025)
          invisible(NULL)
        }
        state$cancel_beat <- later::later(heartbeat, delay = 0.025)
        session$onSessionEnded(function() {
          state$closed <- TRUE
          if (is.function(state$cancel_beat)) state$cancel_beat()
        })
        resolver <- function(path, ...) {
          started <- clock()
          if (delay_ms > 0) Sys.sleep(delay_ms / 1000)
          metadata_started <- clock()
          resolved <- shinyAssistantUI:::.addin_resolve_file_path(path, fixture_project)
          completed <- clock()
          if (state$phase != "idle") {
            metric <- state$metrics[[state$phase]]
            metric$lookupMs <- c(metric$lookupMs, completed - started)
            metric$metadataMs <- c(metric$metadataMs, completed - metadata_started)
            state$metrics[[state$phase]] <- metric
          }
          resolved
        }
        controls <- assistantUIServer(
          "chat", handler = function(message, on_chunk, on_done, ...) {
            on_chunk("BENCH_REPLY_OK")
            on_done()
          },
          persistence = "server", show_thread_list = TRUE, working_dir = fixture_project,
          on_open_file = if (enabled) function(...) invisible(NULL) else NULL,
          file_reference_resolver = if (enabled) resolver else NULL,
          on_session_load = function(session_id, thread_id, send_thread, ...) {
            begin("initial")
            send_thread(history, has_more = FALSE)
          }
        )
        observeEvent(input$advance, {
          phase <- state$phase
          if (phase == "idle") return()
          report <- state$metrics[[phase]]
          report$elapsedMs <- clock() - report$started
          report$rssAfterMiB <- rss()
          session$sendCustomMessage("file-reference-benchmark-report", list(phase = phase, metrics = report))
          if (phase == "initial") begin("steady") else state$phase <- "idle"
        }, ignoreInit = TRUE)
        session$onFlushed(function() {
          controls$send_sessions(list(sessions = list(list(
            id = "file-perf-history", title = "File reference performance history"
          ))))
        }, once = TRUE)
      }
      shiny::runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
    }, args = list(home_lib = home_lib, fixture_project = fixture_project, port = port,
                   enabled = enabled, delay_ms = delay_ms),
    stdout = stdout, stderr = stderr, supervise = TRUE,
    env = c(HOME = home, R_LIBS_USER = home_lib))
    wait_until <- function(predicate, timeout = 15) {
      deadline <- Sys.time() + timeout
      repeat {
        if (isTRUE(predicate())) return(TRUE)
        if (!app$is_alive() || Sys.time() >= deadline) return(FALSE)
        Sys.sleep(0.02)
      }
    }
    if (!wait_until(function() any(grepl("Listening on", read_log(stderr), fixed = TRUE)), 25)) {
      stop(paste(c(read_log(stdout), read_log(stderr)), collapse = "\n"), call. = FALSE)
    }
    chromote::set_chrome_args(unique(c(
      chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
    )))
    browser <- ChromoteSession$new(parent = chromote::Chromote$new(), width = 1100, height = 900)
    phase <- "mount"
    console_errors <- runtime_errors <- network_errors <- character()
    confirmation_warnings <- character()
    requests <- replies <- list()
    window_errors <- capture_browser_window_errors(browser, function() paste(arm, phase))
    browser$Network$enable()
    browser$Performance$enable()
    browser$Runtime$consoleAPICalled(callback_ = function(event) {
      if (identical(event$type, "error")) console_errors <<- c(console_errors, "console error")
      if (identical(event$type, "warning") && any(vapply(event$args, function(arg) {
        is.character(arg$value) && grepl("File reference", arg$value, fixed = TRUE)
      }, logical(1)))) confirmation_warnings <<- c(confirmation_warnings, "file reference warning")
    })
    browser$Runtime$exceptionThrown(callback_ = function(event) {
      runtime_errors <<- c(runtime_errors, event$exceptionDetails$text)
    })
    browser$Network$loadingFailed(callback_ = function(event) {
      if (!isTRUE(event$canceled)) network_errors <<- c(network_errors, event$errorText)
    })
    browser$Network$responseReceived(callback_ = function(event) {
      if (event$response$status >= 400) network_errors <<- c(network_errors, "HTTP error")
    })
    browser$Network$webSocketFrameSent(callback_ = function(event) {
      payload <- event$response$payloadData
      if (!grepl("chat_input_resolve_files", payload, fixed = TRUE)) return()
      data <- jsonlite::fromJSON(payload, simplifyVector = FALSE)$data$chat_input_resolve_files
      if (is.null(data)) return()
      requests[[data$requestId]] <<- list(
        phase = phase, sent = event$timestamp * 1000, paths = unlist(data$paths, use.names = FALSE)
      )
    })
    browser$Network$webSocketFrameReceived(callback_ = function(event) {
      payload <- event$response$payloadData
      if (!grepl("chat_input:file-references", payload, fixed = TRUE)) return()
      data <- jsonlite::fromJSON(payload, simplifyVector = FALSE)$custom[["chat_input:file-references"]]
      if (!is.null(data)) replies[[data$requestId]] <<- event$timestamp * 1000
    })
    value <- function(js) {
      result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
      if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
      result$result$value
    }
    wait_js <- function(js, timeout = 15) wait_until(function() isTRUE(value(js)), timeout)
    metrics <- function() {
      values <- browser$Performance$getMetrics()$metrics
      setNames(vapply(values, function(item) item$value, numeric(1)),
               vapply(values, function(item) item$name, character(1)))
    }
    click <- function(selector) {
      stopifnot(wait_js(paste0("!!document.querySelector(", quote_js(selector), ")")))
      point <- value(paste0(
        "(()=>{const e=document.querySelector(", quote_js(selector), "),r=e.getBoundingClientRect();",
        "const x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,visible:r.width>0&&r.height>0&&x>=0&&y>=0&&x<innerWidth&&y<innerHeight&&e.contains(document.elementFromPoint(x,y))}})()"
      ))
      stopifnot(isTRUE(point$visible))
      browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                      button = "left", clickCount = 1L)
      browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                      button = "left", clickCount = 1L)
    }
    focus <- function() stopifnot(isTRUE(value(
      "(()=>{const e=document.querySelector('#chat .aui-lexical-input[contenteditable=true]');if(!e)return false;e.focus();const r=e.getBoundingClientRect();return r.width>0&&r.top>=0&&r.bottom<=innerHeight})()"
    )))
    type_text <- function(text) {
      focus()
      for (character in strsplit(text, "", fixed = TRUE)[[1L]]) {
        browser$Input$insertText(text = character)
        Sys.sleep(0.01)
      }
      stopifnot(wait_js(sprintf(
        "window.__fileReferencePerf.snapshot(%s).inputFrameMs.length===%d",
        quote_js(phase), nchar(text)
      )))
    }
    capture <- function(name, before) {
      js <- value(paste0("window.__fileReferencePerf.snapshot(", quote_js(name), ",true)"))
      delta <- metrics() - before
      click("#advance")
      stopifnot(wait_js(paste0("!!window.__fileReferenceReports[", quote_js(name), "]")))
      backend <- value(paste0("window.__fileReferenceReports[", quote_js(name), "]"))
      own <- Filter(function(request) identical(request$phase, name), requests)
      roundtrips <- vapply(names(own), function(id) {
        if (is.null(replies[[id]])) stop("Missing confirmation reply")
        replies[[id]] - own[[id]]$sent
      }, numeric(1))
      list(
        browser = js,
        inputFrameMs = summarize(js$inputFrameMs),
        longTaskCount = length(js$longTasks),
        scriptMs = unname(delta[["ScriptDuration"]] * 1000),
        layoutMs = unname(delta[["LayoutDuration"]] * 1000),
        taskMs = unname(delta[["TaskDuration"]] * 1000),
        browserHeapMiB = unname(metrics()[["JSHeapUsedSize"]] / 1024^2),
        backend = backend,
        heartbeatMs = summarize(backend$heartbeatMs),
        lookupMs = summarize(backend$lookupMs),
        metadataMs = summarize(backend$metadataMs),
        batchCount = length(own),
        pathsPerBatch = as.list(vapply(own, function(request) length(request$paths), integer(1))),
        batchRoundtripMs = summarize(roundtrips),
        batches = own
      )
    }
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
    stopifnot(wait_js("!!document.querySelector('#chat .aui-lexical-input[contenteditable=true]')", 25))
    value(browser_source)
    value("window.__fileReferenceReports={};Shiny.addCustomMessageHandler('file-reference-benchmark-report',data=>window.__fileReferenceReports[data.phase]=data.metrics);true")
    stopifnot(wait_js(
      "[...document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')].some(e=>e.textContent.includes('File reference performance history'))"
    ))
    value("[...document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')].find(e=>e.textContent.includes('File reference performance history')).setAttribute('data-perf-history','true');true")
    phase <- "initial"
    before <- metrics()
    value(sprintf("window.__fileReferencePerf.begin('initial',%s);true", if (enabled) "true" else "false"))
    click("#chat [data-perf-history=true] button")
    stopifnot(wait_js("window.__fileReferencePerf.snapshot('initial').historyReadyMs!==null"))
    initial_text <- paste(rep("abcdef ", 9L), collapse = "")
    type_text(initial_text)
    stopifnot(wait_js("window.__fileReferencePerf.ready()"))
    Sys.sleep(0.2)
    value("true")
    initial <- capture("initial", before)
    phase <- "steady"
    before <- metrics()
    value(sprintf("window.__fileReferencePerf.begin('steady',%s);true", if (enabled) "true" else "false"))
    type_text(initial_text)
    Sys.sleep(0.15)
    value("true")
    steady <- capture("steady", before)
    stopifnot(
      initial$inputFrameMs$n == nchar(initial_text), steady$inputFrameMs$n == nchar(initial_text),
      initial$browser$mountedMessages > 0L, initial$browser$mountedMessages <= 48L,
      initial$browser$supportsLongTasks, steady$browser$supportsLongTasks,
      initial$heartbeatMs$n > 5L, steady$heartbeatMs$n > 5L,
      steady$batchCount == 0L, steady$lookupMs$n == 0L
    )
    if (enabled) {
      stopifnot(initial$batchCount > 0L, initial$lookupMs$n > 0L,
                initial$browser$unconfirmedReferences == 0L,
                all(unlist(initial$pathsPerBatch) <= 32L))
    } else {
      stopifnot(initial$batchCount == 0L, initial$lookupMs$n == 0L,
                initial$browser$confirmedReferences == 0L)
    }
    if (delay_ms > 0) stopifnot(initial$browser$inputsDuringConfirmation > 0L)
    phase <- "smoke"
    focus()
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    stopifnot(wait_js("document.getElementById('chat').textContent.includes('BENCH_REPLY_OK')"))
    value("true")
    stopifnot(length(console_errors) == 0L, length(runtime_errors) == 0L,
              length(window_errors()) == 0L, length(network_errors) == 0L,
              length(confirmation_warnings) == 0L)
    result <- list(
      arm = arm, repetition = repetition, position = position,
      version = as.character(packageVersion("shinyAssistantUI", lib.loc = home_lib)),
      filesystem = filesystem, historyMessages = 240L, uniqueHistoryFiles = 640L,
      injectedPerLookupMs = delay_ms, kernelCacheCleared = FALSE,
      initial = initial, steady = steady,
      consoleErrors = 0L, runtimeErrors = 0L, windowErrors = 0L, networkErrors = 0L
    )
    saveRDS(result, file.path(output, sprintf("rep-%d-%s.rds", repetition, arm)))
    write_json(result, file.path(output, sprintf("rep-%d-%s.json", repetition, arm)),
               pretty = TRUE, auto_unbox = TRUE, null = "null", digits = NA)
    cat(sprintf(
      "PERF_ARM arm=%s rep=%d history_ms=%.1f input_initial_p95_ms=%.1f input_steady_p95_ms=%.1f heartbeat_max_ms=%.1f lookups=%d batches=%d steady_lookups=%d\n",
      arm, repetition, initial$browser$historyReadyMs, initial$inputFrameMs$p95,
      steady$inputFrameMs$p95, initial$heartbeatMs$max, initial$lookupMs$n, initial$batchCount,
      steady$lookupMs$n
    ))
    cleanup()
    stopifnot(!app$is_alive())
    result
  }
  results <- list()
  for (position in seq_along(orders[[repetition]])) {
    arm <- orders[[repetition]][[position]]
    cat(sprintf("[ARM %d/3] repetition=%d arm=%s\n", position, repetition, arm))
    results[[arm]] <- run_arm(arm, position)
  }
  saveRDS(results, file.path(output, sprintf("repetition-%d.rds", repetition)))
  cat("FILE_REFERENCE_PERFORMANCE_DONE repetition=", repetition, " arms=3 errors=0\n", sep = "")
}

run_file_reference_benchmark()
