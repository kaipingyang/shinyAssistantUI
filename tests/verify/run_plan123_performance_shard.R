#!/usr/bin/env Rscript

source_files <- Filter(Negate(is.null), lapply(sys.frames(), function(frame) frame$ofile))
source_file <- if (length(source_files)) tail(source_files, 1L)[[1L]] else NULL
script_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (!is.null(source_file) && nzchar(source_file)) {
  source_file
} else if (length(script_argument)) {
  sub("^--file=", "", script_argument[[1L]])
} else {
  "tests/verify/run_plan123_performance_shard.R"
}
candidate_dirs <- unique(c(
  dirname(script_path),
  file.path(getwd(), "tests", "verify"),
  file.path(getwd(), "..", "verify"),
  file.path(getwd(), "..", "..", "tests", "verify")
))
valid_dirs <- candidate_dirs[file.exists(file.path(candidate_dirs, "plan123_benchmark_pure.R"))]
if (!length(valid_dirs)) stop("cannot locate tests/verify/plan123_benchmark_pure.R", call. = FALSE)
script_dir <- normalizePath(valid_dirs[[1L]], winslash = "/")
project <- normalizePath(file.path(script_dir, "..", ".."), winslash = "/")
source(file.path(script_dir, "plan123_benchmark_pure.R"), local = TRUE)

PLAN123_VIEWPORT <- list(width = 960L, height = 800L)
PLAN123_HOME_LIBRARY <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

plan123_write_json_atomic <- function(value, path) {
  parent <- dirname(path)
  if (!dir.exists(parent)) dir.create(parent, recursive = TRUE, mode = "0700")
  temporary <- tempfile(paste0(basename(path), "."), tmpdir = parent)
  on.exit(unlink(temporary, force = TRUE), add = TRUE)
  jsonlite::write_json(value, temporary, auto_unbox = TRUE, pretty = TRUE,
                       null = "null", digits = NA)
  if (!file.rename(temporary, path)) plan123_stop("could not publish raw shard artifact")
  invisible(normalizePath(path, winslash = "/"))
}

plan123_sanitize_error <- function(value) {
  text <- as.character(value %||% "unknown error")
  text <- gsub(project, "<project>", text, fixed = TRUE)
  text <- gsub(Sys.getenv("HOME", ""), "<home>", text, fixed = TRUE)
  substr(text, 1L, 1000L)
}

plan123_child_pids <- function() {
  path <- sprintf("/proc/%d/task/%d/children", Sys.getpid(), Sys.getpid())
  if (!file.exists(path)) return(integer())
  scan(path, what = integer(), quiet = TRUE)
}

run_plan123_shard <- function(args = commandArgs(trailingOnly = TRUE)) {
  parsed <- plan123_parse_shard_args(args)
  suppressPackageStartupMessages({
    library(callr)
    library(chromote)
    library(digest)
    library(jsonlite)
  })

  installed <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
  expected_installed <- file.path(PLAN123_HOME_LIBRARY, "shinyAssistantUI")
  if (!identical(installed, expected_installed)) {
    plan123_stop("Plan123 shard must use the fixed HOME-installed package fixture")
  }
  installed_js <- file.path(installed, "www", "shinyAssistantUI.js")
  source_js <- file.path(project, "inst", "www", "shinyAssistantUI.js")
  installed_js_sha <- digest::digest(file = installed_js, algo = "sha256")
  source_js_sha <- digest::digest(file = source_js, algo = "sha256")
  if (!identical(installed_js_sha, source_js_sha)) {
    plan123_stop("installed/source JS hash mismatch")
  }

  fixture_path <- file.path(script_dir, "plan123_performance_app.R")
  sidecar_path <- file.path(script_dir, "plan123_performance_sidecar.js")
  pure_path <- file.path(script_dir, "plan123_benchmark_pure.R")
  aggregate_path <- file.path(script_dir, "aggregate_plan123_performance_shards.R")
  sidecar_source <- paste(readLines(sidecar_path, warn = FALSE), collapse = "\n")
  expected_semantic <- "<p>Fixture result 42.</p>"
  expected_sha <- digest::digest(expected_semantic, algo = "sha256", serialize = FALSE)
  harness_components <- vapply(
    c(pure_path, script_path, aggregate_path),
    function(path) digest::digest(file = path, algo = "sha256"),
    character(1)
  )
  harness_sha <- digest::digest(paste(harness_components, collapse = "|"),
                                algo = "sha256", serialize = FALSE)
  fingerprint <- plan123_fingerprint(
    parsed$seed,
    installed_js_sha256 = installed_js_sha,
    fixture_sha256 = digest::digest(file = fixture_path, algo = "sha256"),
    sidecar_sha256 = digest::digest(file = sidecar_path, algo = "sha256"),
    harness_sha256 = harness_sha,
    package_version = as.character(packageVersion("shinyAssistantUI"))
  )

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter",
    "--no-crash-upload", "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    "--js-flags=--expose-gc"
  )))

  root_browser <- ChromoteSession$new(
    width = PLAN123_VIEWPORT$width,
    height = PLAN123_VIEWPORT$height
  )
  chrome_process <- root_browser$parent$get_browser()$get_process()
  active_app <- NULL
  active_handles <- list()
  app_exit_facts <- logical()
  contexts_disposed <- logical()
  cleanup_done <- FALSE

  cleanup_all <- function() {
    if (cleanup_done) return(invisible(NULL))
    cleanup_done <<- TRUE
    for (handle in rev(active_handles)) {
      try(handle$page$close(), silent = TRUE)
      disposed <- tryCatch({
        root_browser$parent$Target$disposeBrowserContext(browserContextId = handle$contextId)
        TRUE
      }, error = function(error) FALSE)
      contexts_disposed <<- c(contexts_disposed, disposed)
    }
    active_handles <<- list()
    if (!is.null(active_app)) {
      try(if (active_app$process$is_alive()) active_app$process$kill_tree(), silent = TRUE)
      try(active_app$process$wait(timeout = 5000L), silent = TRUE)
      app_exit_facts <<- c(app_exit_facts, !active_app$process$is_alive())
      unlink(c(active_app$stdout, active_app$stderr, active_app$home),
             recursive = TRUE, force = TRUE)
      active_app <<- NULL
    }
    try(root_browser$close(), silent = TRUE)
    try(root_browser$parent$get_browser()$close(), silent = TRUE)
    try(root_browser$parent$close(), silent = TRUE)
    try(if (chrome_process$is_alive()) chrome_process$kill_tree(), silent = TRUE)
    try(chrome_process$wait(timeout = 10000L), silent = TRUE)
    invisible(NULL)
  }
  on.exit(cleanup_all(), add = TRUE)

  start_app <- function(index) {
    home <- tempfile(sprintf("plan123-%s-%02d-home-", parsed$mode, index))
    dir.create(home, recursive = TRUE, mode = "0700")
    port <- httpuv::randomPort()
    stdout <- tempfile(sprintf("plan123-%s-%02d-out-", parsed$mode, index))
    stderr <- tempfile(sprintf("plan123-%s-%02d-err-", parsed$mode, index))
    process <- callr::r_bg(
      function(project, library, port) {
        .libPaths(c(library, .libPaths()))
        setwd(project)
        suppressPackageStartupMessages(library(shiny))
        shiny::runApp(
          file.path("tests", "verify", "plan123_performance_app.R"),
          host = "127.0.0.1", port = port, launch.browser = FALSE
        )
      },
      args = list(project = project, library = PLAN123_HOME_LIBRARY, port = port),
      env = c(HOME = home, R_LIBS_USER = PLAN123_HOME_LIBRARY,
              SAU_PLAN123_EXPECTED_SHA = expected_sha),
      stdout = stdout, stderr = stderr, supervise = FALSE
    )
    deadline <- Sys.time() + 25
    repeat {
      lines <- if (file.exists(stderr)) readLines(stderr, warn = FALSE) else character()
      if (any(grepl("Listening on", lines, fixed = TRUE))) break
      if (!process$is_alive() || Sys.time() >= deadline) {
        try(process$kill_tree(), silent = TRUE)
        plan123_stop("fixed installed app fixture failed to boot")
      }
      Sys.sleep(0.05)
    }
    list(process = process, port = port, stdout = stdout, stderr = stderr, home = home)
  }

  stop_app <- function(app) {
    try(if (app$process$is_alive()) app$process$kill_tree(), silent = TRUE)
    try(app$process$wait(timeout = 5000L), silent = TRUE)
    exited <- !app$process$is_alive()
    app_exit_facts <<- c(app_exit_facts, exited)
    unlink(c(app$stdout, app$stderr, app$home), recursive = TRUE, force = TRUE)
    exited
  }

  eval_value <- function(page, expression, await = FALSE) {
    response <- page$Runtime$evaluate(
      expression = expression, returnByValue = TRUE, awaitPromise = await
    )
    if (!is.null(response$exceptionDetails)) {
      plan123_stop(response$exceptionDetails$exception$description %||%
                     response$exceptionDetails$text %||% "browser evaluation failed")
    }
    response$result$value
  }

  wait_for <- function(page, expression, timeout = 12, interval = 0.025) {
    deadline <- Sys.time() + timeout
    repeat {
      result <- tryCatch(eval_value(page, expression), error = function(error) FALSE)
      if (isTRUE(result)) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(interval)
    }
  }

  new_error_state <- function() {
    state <- new.env(parent = emptyenv())
    state$counts <- list(console = 0L, runtime = 0L, network = 0L,
                         targetCrash = 0L, detached = 0L, externalNetwork = 0L)
    state$details <- list()
    state
  }

  record_error <- function(state, type, detail = type) {
    state$counts[[type]] <- as.integer(state$counts[[type]] %||% 0L) + 1L
    state$details[[length(state$details) + 1L]] <- list(
      type = type, message = plan123_sanitize_error(detail)
    )
  }

  open_page <- function(app, experiment, condition) {
    context <- root_browser$parent$Target$createBrowserContext(disposeOnDetach = FALSE)
    target <- root_browser$parent$Target$createTarget(
      url = "about:blank", browserContextId = context$browserContextId,
      width = PLAN123_VIEWPORT$width, height = PLAN123_VIEWPORT$height,
      background = FALSE
    )
    page <- ChromoteSession$new(
      parent = root_browser$parent, targetId = target$targetId,
      width = PLAN123_VIEWPORT$width, height = PLAN123_VIEWPORT$height
    )
    errors <- new_error_state()
    handle <- list(page = page, contextId = context$browserContextId,
                   targetId = target$targetId, errors = errors)
    active_handles[[length(active_handles) + 1L]] <<- handle
    page$Runtime$enable(); page$Network$enable(); page$Page$enable()
    page$Target$setDiscoverTargets(discover = TRUE)
    page$Runtime$consoleAPICalled(callback_ = function(message) {
      if (identical(message$type, "error")) record_error(errors, "console", "console.error")
    })
    page$Runtime$exceptionThrown(callback_ = function(message) {
      record_error(errors, "runtime", message$exceptionDetails$text %||% "runtime exception")
    })
    page$Network$loadingFailed(callback_ = function(message) {
      if (!identical(message$canceled, TRUE)) record_error(errors, "network", message$errorText)
    })
    page$Network$responseReceived(callback_ = function(message) {
      status <- suppressWarnings(as.numeric(message$response$status %||% 0))
      if (is.finite(status) && status >= 400) record_error(errors, "network", paste("HTTP", status))
    })
    page$Network$requestWillBeSent(callback_ = function(message) {
      url <- as.character(message$request$url %||% "")
      if (nzchar(url) && !grepl("^(http://127\\.0\\.0\\.1:|data:|blob:)", url)) {
        record_error(errors, "externalNetwork", "unexpected external request")
      }
    })
    page$Target$targetCrashed(callback_ = function(message) record_error(errors, "targetCrash"))
    page$Target$detachedFromTarget(callback_ = function(message) record_error(errors, "detached"))
    page$Page$addScriptToEvaluateOnNewDocument(source = sidecar_source)
    root_browser$parent$Target$activateTarget(targetId = target$targetId)
    page$Page$navigate(sprintf(
      "http://127.0.0.1:%d/?experiment=%s&condition=%s",
      app$port, experiment, condition
    ))
    mounted <- wait_for(page, paste0(
      "!!document.querySelector('.aui-root')&&",
      "window.Shiny?.shinyapp?.$socket?.readyState===1&&",
      "!!globalThis.__plan123Perf"
    ), timeout = 20)
    if (!mounted) plan123_stop("fixed installed app fixture did not mount")
    eval_value(page, paste0(
      "Shiny.addCustomMessageHandler('plan123-fixture-receive',",
      "payload=>globalThis.__plan123Perf.receive(payload));true"
    ))
    if (!identical(eval_value(page, "document.visibilityState"), "visible")) {
      root_browser$parent$Target$activateTarget(targetId = target$targetId)
      if (!wait_for(page, "document.visibilityState==='visible'", 3)) {
        plan123_stop("benchmark browser context is not visible")
      }
    }
    handle
  }

  close_page <- function(handle) {
    try(handle$page$close(), silent = TRUE)
    disposed <- tryCatch({
      root_browser$parent$Target$disposeBrowserContext(browserContextId = handle$contextId)
      TRUE
    }, error = function(error) FALSE)
    contexts_disposed <<- c(contexts_disposed, disposed)
    active_handles <<- Filter(
      function(entry) !identical(entry$contextId, handle$contextId),
      active_handles
    )
    invisible(disposed)
  }

  error_counts <- function(handle) handle$errors$counts
  error_details <- function(handle) handle$errors$details

  prepare_history <- function(handle) {
    page <- handle$page
    found <- wait_for(page, paste0(
      "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'))",
      ".some(e=>(e.textContent||'').includes('Fixture history'))"
    ), 8)
    if (!found) plan123_stop("fixed history fixture missing")
    eval_value(page, paste0(
      "(()=>{const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'))",
      ".find(e=>(e.textContent||'').includes('Fixture history'));",
      "(e?.querySelector('[data-slot=aui_thread-list-item-trigger]')||e)?.click();return true})()"
    ))
    if (!wait_for(page, paste0(
      "document.body.innerText.includes('Fixture history response')&&",
      "!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')"
    ), 8)) plan123_stop("fixed history Markdown/tool fixture did not render")
    eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
    invisible(TRUE)
  }

  press_enter <- function(page) {
    page$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                windowsVirtualKeyCode = 13L)
    page$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                windowsVirtualKeyCode = 13L)
  }

  submit_fixture <- function(page, identity) {
    selector <- "document.querySelector('.aui-lexical-input[contenteditable=true]')"
    if (!wait_for(page, paste0("!!", selector), 8)) plan123_stop("composer missing")
    eval_value(page, sprintf("%s.focus();true", selector))
    page$Input$insertText(text = sprintf(
      "fixture::%d::%s", identity$ordinal, identity$instance
    ))
    press_enter(page)
    key <- sprintf("%d:%s", identity$ordinal, identity$instance)
    encoded_key <- jsonlite::toJSON(key, auto_unbox = TRUE)
    if (!wait_for(page, sprintf("globalThis.__plan123Perf.result(%s)?.ok===true", encoded_key), 12)) {
      plan123_stop("semantic DOM hash + MutationObserver quiet milestone failed")
    }
    raw <- eval_value(page, sprintf(
      "JSON.stringify(globalThis.__plan123Perf.result(%s))", encoded_key
    ))
    jsonlite::fromJSON(raw, simplifyVector = FALSE)
  }

  symmetric_frame_probe <- function(page) {
    raw <- eval_value(
      page,
      "globalThis.__plan123Perf.frameProbe(12).then(x=>JSON.stringify(x))",
      await = TRUE
    )
    as.numeric(unlist(jsonlite::fromJSON(raw, simplifyVector = FALSE), use.names = FALSE))
  }

  scheduler_ok <- function(snapshot) {
    identical(as.integer(snapshot$orbRafArms), 0L) &&
      identical(as.integer(snapshot$activeOrbRaf), 0L) &&
      identical(as.integer(snapshot$intervalFires), 0L) &&
      identical(as.integer(snapshot$activeIntervals), 0L) &&
      identical(as.integer(snapshot$domPollArms), 0L)
  }

  measure_latency_side <- function(handle, condition, identity, mode) {
    page <- handle$page
    root_browser$parent$Target$activateTarget(targetId = handle$targetId)
    if (!wait_for(page, "document.visibilityState==='visible'", 3)) {
      plan123_stop("paired browser context is not visible")
    }
    eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
    eval_value(page, "globalThis.__plan123Perf.resetSchedulers();true")
    intervals <- symmetric_frame_probe(page)
    result <- submit_fixture(page, identity)
    if (!wait_for(page, "!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')", 5)) {
      plan123_stop("final fixture tool missing")
    }
    snapshot <- result$scheduler
    common <- list(
      condition = condition,
      fixtureOrdinal = as.integer(result$fixtureOrdinal),
      fixtureInstance = as.character(result$fixtureInstance),
      expectedSemanticSha256 = as.character(result$expectedSha256),
      actualSemanticSha256 = as.character(result$semanticSha256),
      semanticHashMatch = identical(result$expectedSha256, result$semanticSha256),
      quietFrames = as.integer(result$quietFrames),
      quietMs = as.numeric(result$quietMs),
      scheduler = snapshot,
      schedulerOk = scheduler_ok(snapshot),
      errors = error_counts(handle)
    )
    if (identical(mode, "markdown")) {
      return(c(common, list(
        preprocessMs = as.numeric(result$preprocessMs),
        domMilestoneMs = as.numeric(result$receiveToDomMs)
      )))
    }
    c(common, list(
      frameIntervalsMs = intervals,
      frameP95Ms = as.numeric(plan123_nearest_rank(intervals, 0.95)),
      frameMaxMs = max(intervals),
      jankCount = as.integer(sum(intervals > 50)),
      callbackToDomMs = as.numeric(result$callbackToDomMs)
    ))
  }

  settle_heap <- function(page) {
    attempts <- list()
    stable <- FALSE
    stable_values <- numeric()
    for (attempt in seq_len(5L)) {
      try(page$HeapProfiler$collectGarbage(), silent = TRUE)
      eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
      try(page$HeapProfiler$collectGarbage(), silent = TRUE)
      usage <- page$Runtime$getHeapUsage()
      attempts[[attempt]] <- list(
        attempt = attempt,
        usedBytes = as.numeric(usage$usedSize),
        totalBytes = as.numeric(usage$totalSize)
      )
      if (attempt >= 3L) {
        stable_values <- vapply(tail(attempts, 3L), `[[`, numeric(1), "usedBytes")
        if (diff(range(stable_values)) <= PLAN123_MIB) {
          stable <- TRUE
          break
        }
      }
    }
    list(stable = stable,
         usedBytes = if (stable) min(stable_values) else NA_real_,
         attempts = attempts)
  }

  measure_heap_side <- function(handle, condition, identity) {
    page <- handle$page
    page$HeapProfiler$enable()
    baseline <- settle_heap(page)
    result <- submit_fixture(page, identity)
    if (!wait_for(page, "!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')", 5)) {
      plan123_stop("heap fixture tool missing")
    }
    eval_value(page, "document.getElementById('fixture_clear')?.click();true")
    if (!wait_for(page, "!document.querySelector('.aui-root')", 3) ||
        !wait_for(page, "!!document.querySelector('.aui-root')", 8)) {
      plan123_stop("heap fixture clear/remount failed")
    }
    terminal <- settle_heap(page)
    list(
      condition = condition,
      fixtureOrdinal = as.integer(result$fixtureOrdinal),
      fixtureInstance = as.character(result$fixtureInstance),
      baselineBytes = baseline$usedBytes,
      usedBytes = terminal$usedBytes,
      growthBytes = terminal$usedBytes - baseline$usedBytes,
      settled = isTRUE(baseline$stable) && isTRUE(terminal$stable),
      baselineAttempts = baseline$attempts,
      terminalAttempts = terminal$attempts,
      semanticHashMatch = identical(result$expectedSha256, result$semanticSha256),
      quietFrames = as.integer(result$quietFrames),
      quietMs = as.numeric(result$quietMs),
      errors = error_counts(handle)
    )
  }

  conditions_for <- function(mode) {
    if (identical(mode, "O")) {
      list(experiment = "O", values = c("control", "candidate"))
    } else {
      list(experiment = "D", values = c("control", "candidate"))
    }
  }

  placeholder_sample <- function(index, identity, order) {
    list(index = as.integer(index), ordinal = identity$ordinal,
         instance = identity$instance, order = order, integrity = FALSE)
  }

  orders <- plan123_balanced_orders(parsed$seed, parsed$mode)
  indices <- seq.int(parsed$start, length.out = parsed$count)
  samples <- vector("list", parsed$count)
  shard_errors <- list()

  for (position in seq_along(indices)) {
    index <- indices[[position]]
    order <- orders[[index]]
    identity <- plan123_fixture_identity(parsed$mode, index, parsed$seed)
    samples[[position]] <- placeholder_sample(index, identity, order)
    cat(sprintf("[PLAN123_SHARD] mode=%s %s=%d range=%d:%d order=%s\n",
                parsed$mode, parsed$unit, index, parsed$start,
                parsed$start + parsed$count - 1L, order))
    unit_handles <- list()
    unit_app <- NULL
    unit_error <- NULL
    condition_samples <- list()
    config <- conditions_for(parsed$mode)
    sequence <- if (identical(order, "candidate-first")) {
      c("candidate", "control")
    } else {
      c("control", "candidate")
    }

    tryCatch({
      unit_app <- start_app(index)
      active_app <- unit_app
      for (condition in sequence) {
        handle <- open_page(unit_app, config$experiment, condition)
        unit_handles[[condition]] <- handle
        prepare_history(handle)
      }
      for (condition in sequence) {
        condition_samples[[condition]] <- if (identical(parsed$mode, "heap")) {
          measure_heap_side(unit_handles[[condition]], condition, identity)
        } else {
          measure_latency_side(unit_handles[[condition]], condition, identity, parsed$mode)
        }
      }
      same_fixture <- identical(condition_samples$control$fixtureOrdinal,
                                condition_samples$candidate$fixtureOrdinal) &&
        identical(condition_samples$control$fixtureInstance,
                  condition_samples$candidate$fixtureInstance) &&
        identical(condition_samples$control$fixtureOrdinal, identity$ordinal) &&
        identical(condition_samples$control$fixtureInstance, identity$instance)
      integrity <- isTRUE(same_fixture)
      if (!identical(parsed$mode, "heap")) {
        integrity <- integrity && isTRUE(condition_samples$control$semanticHashMatch) &&
          isTRUE(condition_samples$candidate$semanticHashMatch) &&
          condition_samples$control$quietFrames >= 2L &&
          condition_samples$candidate$quietFrames >= 2L &&
          condition_samples$control$quietMs >= 100 &&
          condition_samples$candidate$quietMs >= 100
      }
      for (condition in names(unit_handles)) {
        details <- error_details(unit_handles[[condition]])
        if (length(details)) {
          shard_errors <- c(shard_errors, lapply(details, function(detail) c(
            list(index = index, condition = condition), detail
          )))
        }
      }
      samples[[position]] <- list(
        index = as.integer(index), ordinal = identity$ordinal,
        instance = identity$instance, order = order,
        control = condition_samples$control,
        candidate = condition_samples$candidate,
        integrity = integrity
      )
    }, error = function(error) {
      unit_error <<- conditionMessage(error)
      shard_errors[[length(shard_errors) + 1L]] <<- list(
        index = as.integer(index), type = "unit", message = plan123_sanitize_error(unit_error)
      )
    }, finally = {
      for (handle in rev(unit_handles)) close_page(handle)
      if (!is.null(unit_app)) {
        stop_app(unit_app)
        if (identical(active_app, unit_app)) active_app <- NULL
      }
    })
  }

  cleanup_all()
  invisible(gc())
  supervisors <- plan123_child_pids()
  supervisors <- supervisors[vapply(supervisors, function(pid) {
    path <- sprintf("/proc/%d/comm", pid)
    value <- if (file.exists(path)) tryCatch(readLines(path, warn = FALSE, n = 1L), error = function(error) "") else ""
    length(value) && identical(value[[1L]], "supervisor")
  }, logical(1))]
  for (pid in supervisors) try(tools::pskill(pid, tools::SIGTERM), silent = TRUE)
  supervisor_deadline <- Sys.time() + 2
  while (length(intersect(plan123_child_pids(), supervisors)) && Sys.time() < supervisor_deadline) {
    Sys.sleep(0.05)
  }
  for (pid in intersect(plan123_child_pids(), supervisors)) {
    try(tools::pskill(pid, tools::SIGKILL), silent = TRUE)
  }
  deadline <- Sys.time() + 10
  children <- plan123_child_pids()
  while (length(children) && Sys.time() < deadline) {
    Sys.sleep(0.05)
    invisible(gc())
    children <- plan123_child_pids()
  }
  child_names <- vapply(children, function(pid) {
    path <- sprintf("/proc/%d/comm", pid)
    if (!file.exists(path)) return("exited")
    value <- tryCatch(readLines(path, warn = FALSE, n = 1L), error = function(error) "unknown")
    if (length(value)) substr(value[[1L]], 1L, 64L) else "unknown"
  }, character(1))
  cleanup <- list(
    appExited = length(app_exit_facts) == parsed$count && all(app_exit_facts),
    browserContextDisposed = length(contexts_disposed) == parsed$count * 2L &&
      all(contexts_disposed),
    activeChildren = as.integer(length(children)),
    activeChildNames = as.list(child_names)
  )
  if (!cleanup$appExited) {
    shard_errors[[length(shard_errors) + 1L]] <- list(type = "cleanup", message = "app did not exit")
  }
  if (!cleanup$browserContextDisposed) {
    shard_errors[[length(shard_errors) + 1L]] <- list(type = "cleanup", message = "browser context not disposed")
  }
  if (cleanup$activeChildren != 0L) {
    shard_errors[[length(shard_errors) + 1L]] <- list(type = "cleanup", message = "owned children remain")
  }

  shard <- plan123_new_shard(
    fingerprint = fingerprint,
    mode = parsed$mode,
    start = parsed$start,
    count = parsed$count,
    seed = parsed$seed,
    samples = samples,
    errors = shard_errors,
    cleanup = cleanup
  )
  plan123_write_json_atomic(shard, parsed$artifactPath)
  cat("PLAN123_SHARD_ARTIFACT=", normalizePath(parsed$artifactPath, winslash = "/"), "\n", sep = "")
  cat(sprintf("PLAN123_SHARD_CLEANUP appExited=%s browserContextDisposed=%s activeChildren=%d\n",
              cleanup$appExited, cleanup$browserContextDisposed, cleanup$activeChildren))
  if (length(shard_errors)) {
    plan123_stop("Plan123 shard completed with errors; raw artifact was preserved")
  }
  cat(sprintf("PLAN123_SHARD_PASS mode=%s start=%d count=%d fingerprint=%s\n",
              parsed$mode, parsed$start, parsed$count, substr(fingerprint, 1L, 12L)))
  invisible(shard)
}

if (sys.nframe() == 0L) run_plan123_shard()
