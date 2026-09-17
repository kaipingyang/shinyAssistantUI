#!/usr/bin/env Rscript

MEASURED_PAIRS <- 30L
WARMUP_PAIRS <- 2L
FIXED_SEED <- 1231501L
MIB <- 1024^2
VIEWPORT <- list(width = 960L, height = 800L)

nearest_rank <- function(values, probability) {
  stopifnot(length(values) > 0L, is.finite(probability), probability > 0, probability <= 1)
  sort(values, na.last = NA)[[ceiling(probability * length(values))]]
}

least_squares_slope <- function(x, y) {
  stopifnot(length(x) == length(y), length(x) >= 2L)
  x_centered <- x - mean(x)
  sum(x_centered * (y - mean(y))) / sum(x_centered^2)
}

heap_budget_verdict <- function(baseline, end, slope_bytes_per_cycle) {
  growth <- end - baseline
  list(
    ok = is.finite(growth) && is.finite(slope_bytes_per_cycle) &&
      growth <= 8 * MIB && slope_bytes_per_cycle <= 0.25 * MIB,
    growthBytes = growth,
    slopeBytesPerCycle = slope_bytes_per_cycle,
    growthBudgetBytes = 8 * MIB,
    slopeBudgetBytesPerCycle = 0.25 * MIB
  )
}

`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

run_plan123_gate <- function() {
  suppressPackageStartupMessages({
    library(callr)
    library(chromote)
    library(digest)
    library(jsonlite)
  })

  project <- normalizePath(getwd(), winslash = "/")
  home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  installed <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
  expected_installed <- file.path(home_library, "shinyAssistantUI")
  if (!identical(installed, expected_installed)) {
    stop("Plan123 gate must use the HOME-installed package")
  }
  source(file.path(project, "tests", "verify", "owned_process_cleanup.R"), local = TRUE)
  sidecar_path <- file.path(project, "tests", "verify", "plan123_performance_sidecar.js")
  sidecar_source <- paste(readLines(sidecar_path, warn = FALSE), collapse = "\n")
  expected_semantic <- "<p>Fixture result 42.</p>"
  expected_sha <- digest::digest(expected_semantic, algo = "sha256", serialize = FALSE)
  package_version <- as.character(packageVersion("shinyAssistantUI"))
  installed_js <- file.path(installed, "www", "shinyAssistantUI.js")
  source_js <- file.path(project, "inst", "www", "shinyAssistantUI.js")
  installed_js_sha <- digest::digest(file = installed_js, algo = "sha256")
  source_js_sha <- digest::digest(file = source_js, algo = "sha256")
  if (!identical(installed_js_sha, source_js_sha)) stop("installed/source JS hash mismatch")

  set.seed(FIXED_SEED)
  measured_orders <- sample(rep(c("candidate-first", "control-first"), each = MEASURED_PAIRS / 2L))
  warmup_orders <- c("control-first", "candidate-first")
  instance_for <- function(experiment, round, phase = "measured", cycle = 0L) {
    substr(digest::digest(
      sprintf("%d|%s|%s|%d|%d", FIXED_SEED, experiment, phase, round, cycle),
      algo = "sha256", serialize = FALSE
    ), 1L, 32L)
  }
  ordinal_for <- function(experiment, round, phase = "measured", cycle = 0L) {
    base <- if (identical(experiment, "D")) 100000L else 200000L
    phase_offset <- if (identical(phase, "warmup")) 1000L else if (identical(phase, "heap")) 2000L else 0L
    base + phase_offset + round * 100L + cycle + 1L
  }

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter",
    "--no-crash-upload", "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    "--js-flags=--expose-gc"
  )))
  root_browser <- ChromoteSession$new(width = VIEWPORT$width, height = VIEWPORT$height)
  chrome_process <- root_browser$parent$get_browser()$get_process()
  active_app <- NULL
  active_pages <- list()
  orb_signatures <- character()
  cleanup_root <- function() {
    for (entry in rev(active_pages)) {
      try(entry$session$close(), silent = TRUE)
      try(root_browser$parent$Target$disposeBrowserContext(browserContextId = entry$contextId), silent = TRUE)
    }
    active_pages <<- list()
    if (!is.null(active_app)) {
      try(if (active_app$process$is_alive()) active_app$process$kill_tree(), silent = TRUE)
      try(active_app$process$wait(timeout = 5000L), silent = TRUE)
      active_app <<- NULL
    }
    try(root_browser$close(), silent = TRUE)
    try(root_browser$parent$get_browser()$close(), silent = TRUE)
    try(root_browser$parent$close(), silent = TRUE)
    try(if (chrome_process$is_alive()) chrome_process$kill_tree(), silent = TRUE)
    try(chrome_process$wait(timeout = 10000L), silent = TRUE)
    invisible(gc())
  }
  on.exit(cleanup_root(), add = TRUE)

  start_app <- function(home) {
    port <- httpuv::randomPort()
    stdout <- tempfile("plan123-app-out-")
    stderr <- tempfile("plan123-app-err-")
    process <- callr::r_bg(
      function(project, home_library, port) {
        .libPaths(c(home_library, .libPaths()))
        setwd(project)
        suppressPackageStartupMessages(library(shiny))
        shiny::runApp(
          file.path("tests", "verify", "plan123_performance_app.R"),
          host = "127.0.0.1", port = port, launch.browser = FALSE
        )
      },
      args = list(project = project, home_library = home_library, port = port),
      env = c(
        HOME = home, R_LIBS_USER = home_library,
        SAU_PLAN123_EXPECTED_SHA = expected_sha
      ),
      stdout = stdout, stderr = stderr, supervise = TRUE
    )
    deadline <- Sys.time() + 35
    repeat {
      lines <- if (file.exists(stderr)) readLines(stderr, warn = FALSE) else character()
      if (any(grepl("Listening on", lines, fixed = TRUE))) break
      if (!process$is_alive() || Sys.time() >= deadline) {
        stop("Plan123 fixture failed to boot: ", paste(tail(lines, 10L), collapse = " | "))
      }
      Sys.sleep(0.05)
    }
    list(process = process, port = port, stdout = stdout, stderr = stderr, home = home)
  }
  stop_app <- function(app) {
    was_alive <- app$process$is_alive()
    if (was_alive) try(app$process$kill_tree(), silent = TRUE)
    try(app$process$wait(timeout = 5000L), silent = TRUE)
    alive <- app$process$is_alive()
    unlink(c(app$stdout, app$stderr, app$home), recursive = TRUE, force = TRUE)
    list(wasAlive = was_alive, exited = !alive)
  }

  eval_value <- function(page, expression, await = FALSE) {
    response <- page$Runtime$evaluate(
      expression = expression, returnByValue = TRUE, awaitPromise = await
    )
    if (!is.null(response$exceptionDetails)) {
      stop(response$exceptionDetails$exception$description %||%
             response$exceptionDetails$text %||% "browser evaluation failed")
    }
    response$result$value
  }
  wait_for <- function(page, expression, timeout = 15, interval = 0.025) {
    deadline <- Sys.time() + timeout
    repeat {
      value <- tryCatch(eval_value(page, expression), error = function(error) FALSE)
      if (isTRUE(value)) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(interval)
    }
  }
  open_page <- function(app, experiment, condition) {
    context <- root_browser$parent$Target$createBrowserContext(disposeOnDetach = FALSE)
    target <- root_browser$parent$Target$createTarget(
      url = "about:blank", browserContextId = context$browserContextId,
      width = VIEWPORT$width, height = VIEWPORT$height, background = FALSE
    )
    page <- ChromoteSession$new(
      parent = root_browser$parent, targetId = target$targetId,
      width = VIEWPORT$width, height = VIEWPORT$height
    )
    entry <- list(session = page, contextId = context$browserContextId)
    active_pages[[length(active_pages) + 1L]] <<- entry
    errors <- new.env(parent = emptyenv())
    errors$console <- 0L; errors$runtime <- 0L; errors$network <- 0L
    errors$target_crash <- 0L; errors$detach <- 0L; errors$external_network <- 0L
    page$Runtime$enable(); page$Network$enable(); page$Page$enable(); page$Target$setDiscoverTargets(discover = TRUE)
    page$Runtime$consoleAPICalled(callback_ = function(message) {
      if (identical(message$type, "error")) errors$console <- errors$console + 1L
    })
    page$Runtime$exceptionThrown(callback_ = function(message) errors$runtime <- errors$runtime + 1L)
    page$Network$loadingFailed(callback_ = function(message) {
      if (!identical(message$canceled, TRUE)) errors$network <- errors$network + 1L
    })
    page$Network$responseReceived(callback_ = function(message) {
      status <- suppressWarnings(as.numeric(message$response$status %||% 0))
      if (is.finite(status) && status >= 400) errors$network <- errors$network + 1L
    })
    page$Network$requestWillBeSent(callback_ = function(message) {
      url <- as.character(message$request$url %||% "")
      if (nzchar(url) && !grepl("^(http://127\\.0\\.0\\.1:|data:|blob:)", url)) {
        errors$external_network <- errors$external_network + 1L
      }
    })
    page$Target$targetCrashed(callback_ = function(message) errors$target_crash <- errors$target_crash + 1L)
    page$Target$detachedFromTarget(callback_ = function(message) errors$detach <- errors$detach + 1L)
    page$Page$addScriptToEvaluateOnNewDocument(source = sidecar_source)
    root_browser$parent$Target$activateTarget(targetId = target$targetId)
    url <- sprintf(
      "http://127.0.0.1:%d/?experiment=%s&condition=%s",
      app$port, experiment, condition
    )
    page$Page$navigate(url = url)
    mounted <- wait_for(page, paste0(
      "!!document.querySelector('.aui-root')&&",
      "window.Shiny?.shinyapp?.$socket?.readyState===1&&",
      "!!globalThis.__plan123Perf"
    ), timeout = 20)
    if (!mounted) {
      browser_state <- tryCatch(eval_value(page, paste0(
        "JSON.stringify({href:location.href,ready:document.readyState,sidecar:!!globalThis.__plan123Perf,",
        "shiny:!!window.Shiny,socket:window.Shiny?.shinyapp?.$socket?.readyState??null,",
        "root:!!document.querySelector('.aui-root'),body:(document.body?.innerText||'').slice(0,300)})"
      )), error = function(error) conditionMessage(error))
      app_tail <- if (file.exists(app$stderr)) paste(tail(readLines(app$stderr, warn = FALSE), 20L), collapse = " | ") else "missing stderr"
      stop("Plan123 page did not mount; browser=", browser_state,
           "; errors=", jsonlite::toJSON(as.list(errors), auto_unbox = TRUE),
           "; app=", app_tail)
    }
    eval_value(page, paste0(
      "Shiny.addCustomMessageHandler('plan123-fixture-receive',",
      "payload=>globalThis.__plan123Perf.receive(payload));true"
    ))
    if (length(orb_signatures)) {
      encoded_signatures <- jsonlite::toJSON(as.list(orb_signatures), auto_unbox = FALSE)
      if (!isTRUE(eval_value(page, sprintf("globalThis.__plan123Perf.seedOrbSignatures(%s)", encoded_signatures)))) {
        stop("failed to seed Orb scheduler signatures")
      }
    }
    if (!identical(eval_value(page, "document.visibilityState"), "visible")) {
      root_browser$parent$Target$activateTarget(targetId = target$targetId)
      if (!wait_for(page, "document.visibilityState==='visible'", 3)) stop("benchmark target is not visible")
    }
    list(page = page, contextId = context$browserContextId, targetId = target$targetId, errors = errors)
  }
  close_page <- function(handle) {
    try(handle$page$close(), silent = TRUE)
    try(root_browser$parent$Target$disposeBrowserContext(browserContextId = handle$contextId), silent = TRUE)
    active_pages <<- Filter(function(entry) !identical(entry$contextId, handle$contextId), active_pages)
    invisible(NULL)
  }
  error_counts <- function(handle) as.list(handle$errors)

  press_enter <- function(page) {
    page$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    page$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  }
  submit_fixture <- function(page, ordinal, instance) {
    input <- "document.querySelector('.aui-lexical-input[contenteditable=true]')"
    if (!wait_for(page, paste0("!!", input), 10)) stop("composer missing")
    eval_value(page, sprintf("%s.focus();true", input))
    page$Input$insertText(text = sprintf("fixture::%d::%s", ordinal, instance))
    press_enter(page)
    key <- sprintf("%d:%s", ordinal, instance)
    encoded_key <- jsonlite::toJSON(key, auto_unbox = TRUE)
    if (!wait_for(page, sprintf("globalThis.__plan123Perf.result(%s)?.ok===true", encoded_key), 12)) {
      raw <- eval_value(page, sprintf("JSON.stringify(globalThis.__plan123Perf.result(%s)||null)", encoded_key))
      parsed <- tryCatch(jsonlite::fromJSON(raw, simplifyVector = FALSE), error = function(error) NULL)
      stop("fixture DOM milestone failed: reason=", parsed$reason %||% "missing",
           ", textMatch=", parsed$textMatch %||% FALSE,
           ", semantic=", parsed$semanticProjection %||% "missing")
    }
    raw <- eval_value(page, sprintf("JSON.stringify(globalThis.__plan123Perf.result(%s))", encoded_key))
    jsonlite::fromJSON(raw, simplifyVector = FALSE)
  }
  sanitize_sample <- function(result, condition) {
    intervals <- as.numeric(unlist(result$frameIntervals, use.names = FALSE))
    list(
      condition = condition,
      fixtureOrdinal = as.integer(result$fixtureOrdinal),
      fixtureInstance = result$fixtureInstance,
      expectedSemanticSha256 = result$expectedSha256,
      actualSemanticSha256 = result$semanticSha256,
      textMatch = isTRUE(result$textMatch),
      preprocessMs = as.numeric(result$preprocessMs),
      domMilestoneMs = as.numeric(result$receiveToDomMs),
      callbackToDomMs = as.numeric(result$callbackToDomMs),
      serverCallbackToDomMs = as.numeric(result$serverCallbackToDomMs),
      quietFrames = as.integer(result$quietFrames),
      quietMs = as.numeric(result$quietMs),
      frameIntervalsMs = intervals,
      frameP95Ms = nearest_rank(intervals, 0.95),
      frameMaxMs = max(intervals),
      jankCount = sum(intervals > 50),
      scheduler = result$scheduler
    )
  }
  condition_sequence <- function(order) {
    if (identical(order, "candidate-first")) c("candidate", "control") else c("control", "candidate")
  }

  prepare_condition <- function(app, experiment, condition) {
    handle <- open_page(app, experiment, condition)
    page <- handle$page
    history_ready <- wait_for(page, "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.textContent||'').includes('Fixture history'))", 8)
    if (!history_ready) { close_page(handle); stop("latency history fixture missing") }
    eval_value(page, "(()=>{const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>(e.textContent||'').includes('Fixture history'));(e?.querySelector('[data-slot=aui_thread-list-item-trigger]')||e)?.click();return true})()")
    if (!wait_for(page, "document.body.innerText.includes('Fixture history response')&&!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')", 8)) {
      close_page(handle); stop("latency history Markdown/tool did not render")
    }
    eval_value(page, "new Promise(r=>setTimeout(r,500)).then(()=>globalThis.__plan123Perf.settle()).then(()=>true)", await = TRUE)
    handle
  }

  measure_condition <- function(handle, condition, ordinal, instance) {
    page <- handle$page
    root_browser$parent$Target$activateTarget(targetId = handle$targetId)
    if (!wait_for(page, "document.visibilityState==='visible'", 3)) stop("paired target is not visible")
    eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
    eval_value(page, "globalThis.__plan123Perf.resetSchedulers();true")
    result <- submit_fixture(page, ordinal, instance)
    final_tool <- wait_for(page, "!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')", 5)
    shiny_connected <- isTRUE(eval_value(page, "window.Shiny?.shinyapp?.$socket?.readyState===1"))
    fallback <- isTRUE(eval_value(page, "!!document.querySelector('.aui-error-boundary,.aui-fallback')"))
    sched <- result$scheduler
    scheduler_ok <- identical(as.integer(sched$orbRafArms), 0L) &&
      identical(as.integer(sched$activeOrbRaf), 0L) &&
      identical(as.integer(sched$intervalFires), 0L) &&
      identical(as.integer(sched$activeIntervals), 0L) &&
      identical(as.integer(sched$domPollArms), 0L)
    sample <- sanitize_sample(result, condition)
    sample$finalTool <- final_tool
    sample$shinyConnected <- shiny_connected
    sample$fallback <- fallback
    sample$schedulerOk <- scheduler_ok
    sample$errors <- error_counts(handle)
    sample
  }

  run_pair <- function(experiment, round, phase, order) {
    home <- tempfile(sprintf("plan123-%s-%s-%02d-home-", experiment, phase, round))
    dir.create(home, recursive = TRUE, mode = "0700")
    app <- start_app(home)
    active_app <<- app
    ordinal <- ordinal_for(experiment, round, phase)
    instance <- instance_for(experiment, round, phase)
    sequence <- condition_sequence(order)
    handles <- list(); samples <- list(); pair_error <- NULL
    for (condition in sequence) {
      handles[[condition]] <- tryCatch(
        prepare_condition(app, experiment, condition),
        error = function(error) { pair_error <<- conditionMessage(error); NULL }
      )
      if (!is.null(pair_error)) break
    }
    if (is.null(pair_error)) {
      for (condition in sequence) {
        samples[[condition]] <- tryCatch(
          measure_condition(handles[[condition]], condition, ordinal, instance),
          error = function(error) { pair_error <<- conditionMessage(error); NULL }
        )
        if (!is.null(pair_error)) break
      }
    }
    for (handle in Filter(Negate(is.null), handles)) close_page(handle)
    app_error_tail <- if (file.exists(app$stderr)) paste(tail(readLines(app$stderr, warn = FALSE), 30L), collapse = " | ") else "missing stderr"
    app_status <- stop_app(app)
    active_app <<- NULL
    if (!is.null(pair_error)) stop(pair_error, "; app=", app_error_tail)
    control <- samples$control; candidate <- samples$candidate
    same_fixture <- identical(control$fixtureOrdinal, candidate$fixtureOrdinal) &&
      identical(control$fixtureInstance, candidate$fixtureInstance) &&
      identical(control$expectedSemanticSha256, candidate$expectedSemanticSha256)
    list(
      experiment = experiment, phase = phase, round = round, order = order,
      fixtureOrdinal = ordinal, fixtureInstance = instance,
      sameFixture = same_fixture, app = app_status, samples = samples,
      deltas = list(
        frameP95Ms = candidate$frameP95Ms - control$frameP95Ms,
        frameMaxMs = candidate$frameMaxMs - control$frameMaxMs,
        jankCount = candidate$jankCount - control$jankCount,
        preprocessMs = candidate$preprocessMs - control$preprocessMs,
        domMilestoneMs = candidate$domMilestoneMs - control$domMilestoneMs,
        callbackToDomMs = candidate$callbackToDomMs - control$callbackToDomMs,
        serverCallbackToDomMs = candidate$serverCallbackToDomMs - control$serverCallbackToDomMs
      )
    )
  }

  preflight_home <- tempfile("plan123-preflight-home-")
  dir.create(preflight_home, recursive = TRUE, mode = "0700")
  preflight_app <- start_app(preflight_home); active_app <- preflight_app
  preflight_page <- open_page(preflight_app, "O", "candidate")
  preflight <- tryCatch({
    page <- preflight_page$page
    long_task <- jsonlite::fromJSON(eval_value(
      page, "globalThis.__plan123Perf.longTaskPreflight().then(x=>JSON.stringify(x))", await = TRUE
    ), simplifyVector = FALSE)
    eval_value(page, "globalThis.__plan123Perf.resetSchedulers();globalThis.__plan123Perf.beginOrbProfile();true")
    eval_value(page, "document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.click();true")
    expanded <- wait_for(page, "globalThis.__plan123Perf.schedulerSnapshot().rafFires>=3", 5)
    orb_signatures <- as.character(jsonlite::fromJSON(eval_value(
      page, "JSON.stringify(globalThis.__plan123Perf.endOrbProfile())"
    )))
    orb_signature_count <- length(orb_signatures)
    expanded_snapshot <- jsonlite::fromJSON(eval_value(
      page, "JSON.stringify(globalThis.__plan123Perf.schedulerSnapshot())"
    ), simplifyVector = FALSE)
    eval_value(page, "document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.click();true")
    eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
    collapsed_snapshot <- jsonlite::fromJSON(eval_value(
      page, "JSON.stringify(globalThis.__plan123Perf.schedulerSnapshot())"
    ), simplifyVector = FALSE)
    list(
      longTask = long_task,
      orbExpandedFrames = expanded,
      orbSignatureCount = orb_signature_count,
      expandedScheduler = expanded_snapshot,
      collapsedScheduler = collapsed_snapshot,
      errors = error_counts(preflight_page),
      ok = isTRUE(long_task$supported) && as.integer(long_task$beforeClear$count) >= 1L &&
        identical(long_task$beforeClear$count, long_task$beforeClear$unique) &&
        identical(as.integer(long_task$afterClear$count), 0L) && expanded &&
        orb_signature_count >= 1L && as.integer(expanded_snapshot$orbRafArms) >= 3L &&
        identical(as.integer(collapsed_snapshot$activeOrbRaf), 0L)
    )
  }, finally = close_page(preflight_page))
  preflight_app_status <- stop_app(preflight_app); active_app <- NULL
  preflight$app <- preflight_app_status

  latency_fingerprint <- digest::digest(paste(
    installed_js_sha,
    digest::digest(file = sidecar_path, algo = "sha256"),
    digest::digest(file = file.path(project, "tests", "verify", "plan123_performance_app.R"), algo = "sha256"),
    digest::digest(file = file.path(project, "tests", "verify", "verify_plan123_performance_gate.R"), algo = "sha256"),
    FIXED_SEED, WARMUP_PAIRS, MEASURED_PAIRS, paste(measured_orders, collapse = ","),
    sep = "|"
  ), algo = "sha256", serialize = FALSE)
  checkpoint_path <- file.path(project, ".kiro", "verification-state", "plan126-latency-checkpoint.rds")
  checkpoint <- if (file.exists(checkpoint_path)) tryCatch(readRDS(checkpoint_path), error = function(error) NULL) else NULL
  if (is.list(checkpoint) && identical(checkpoint$fingerprint, latency_fingerprint)) {
    warmups <- checkpoint$warmups
    measured <- checkpoint$measured
    cat(sprintf("[CHECKPOINT] reused complete D/O latency raw fingerprint=%s\n", substr(latency_fingerprint, 1L, 12L)))
  } else {
    warmups <- list(); measured <- list()
    for (experiment in c("D", "O")) {
      warmups[[experiment]] <- lapply(seq_len(WARMUP_PAIRS), function(round) {
        cat(sprintf("[WARMUP] experiment=%s pair=%d/%d order=%s\n", experiment, round, WARMUP_PAIRS, warmup_orders[[round]]))
        run_pair(experiment, round, "warmup", warmup_orders[[round]])
      })
      measured[[experiment]] <- lapply(seq_len(MEASURED_PAIRS), function(round) {
        cat(sprintf("[MEASURED] experiment=%s pair=%d/%d order=%s\n", experiment, round, MEASURED_PAIRS, measured_orders[[round]]))
        run_pair(experiment, round, "measured", measured_orders[[round]])
      })
    }
    dir.create(dirname(checkpoint_path), recursive = TRUE, mode = "0700", showWarnings = FALSE)
    checkpoint_tmp <- paste0(checkpoint_path, ".", Sys.getpid(), ".tmp")
    saveRDS(list(fingerprint = latency_fingerprint, warmups = warmups, measured = measured), checkpoint_tmp)
    if (!file.rename(checkpoint_tmp, checkpoint_path)) stop("cannot publish latency checkpoint")
    cat(sprintf("[CHECKPOINT] wrote complete D/O latency raw fingerprint=%s\n", substr(latency_fingerprint, 1L, 12L)))
  }

  perform_heap_cycle <- function(page, experiment, condition, cycle, phase) {
    if (wait_for(page, "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.textContent||'').includes('Fixture history'))", 5)) {
      eval_value(page, "(()=>{const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>(e.textContent||'').includes('Fixture history'));(e?.querySelector('[data-slot=aui_thread-list-item-trigger]')||e)?.click();return true})()")
      wait_for(page, "document.body.innerText.includes('Fixture history response')", 5)
    }
    ordinal <- ordinal_for(experiment, 90L, "heap", cycle)
    instance <- instance_for(experiment, 90L, paste0("heap-", condition, "-", phase), cycle)
    result <- submit_fixture(page, ordinal, instance)
    if (!wait_for(page, "!!document.querySelector('[data-slot=tool-fallback-root],[data-slot=tool-group-root]')", 5)) stop("heap tool missing")
    eval_value(page, "document.getElementById('fixture_clear')?.click();true")
    if (!wait_for(page, "!document.querySelector('.aui-root')", 3) ||
        !wait_for(page, "!!document.querySelector('.aui-root')", 8)) stop("heap clear/remount failed")
    list(ordinal = ordinal, instance = instance, domMilestoneMs = result$receiveToDomMs)
  }
  settle_heap <- function(page) {
    attempts <- list(); stable <- FALSE; stable_values <- numeric()
    for (attempt in seq_len(5L)) {
      eval_value(page, "globalThis.__plan123Perf.settle().then(()=>true)", await = TRUE)
      page$HeapProfiler$collectGarbage()
      usage <- page$Runtime$getHeapUsage()
      attempts[[attempt]] <- list(
        attempt = attempt, usedSize = as.numeric(usage$usedSize),
        totalSize = as.numeric(usage$totalSize), scheduler = jsonlite::fromJSON(eval_value(
          page, "JSON.stringify(globalThis.__plan123Perf.schedulerSnapshot())"
        ), simplifyVector = FALSE)
      )
      if (attempt >= 3L) {
        stable_values <- vapply(tail(attempts, 3L), `[[`, numeric(1), "usedSize")
        if (diff(range(stable_values)) <= MIB) { stable <- TRUE; break }
      }
    }
    list(stable = stable, value = if (stable) min(stable_values) else NA_real_, attempts = attempts)
  }
  run_heap_condition <- function(experiment, condition) {
    home <- tempfile(sprintf("plan123-heap-%s-%s-home-", experiment, condition))
    dir.create(home, recursive = TRUE, mode = "0700")
    app <- start_app(home); active_app <<- app
    handle <- open_page(app, experiment, condition)
    page <- handle$page
    page$HeapProfiler$enable()
    warm <- lapply(seq_len(2L), function(cycle) perform_heap_cycle(page, experiment, condition, cycle, "warmup"))
    baseline <- settle_heap(page)
    points <- vector("list", 30L)
    cycles <- vector("list", 30L)
    for (cycle in seq_len(30L)) {
      cat(sprintf("[HEAP] experiment=%s condition=%s cycle=%d/30\n", experiment, condition, cycle))
      cycles[[cycle]] <- perform_heap_cycle(page, experiment, condition, cycle, "measured")
      points[[cycle]] <- settle_heap(page)
    }
    final_instance <- instance_for(experiment, 99L, paste0("heap-final-", condition), 1L)
    final_ordinal <- ordinal_for(experiment, 99L, "heap", 1L)
    final_round_trip <- submit_fixture(page, final_ordinal, final_instance)
    errors <- error_counts(handle)
    connected <- isTRUE(eval_value(page, "window.Shiny?.shinyapp?.$socket?.readyState===1"))
    close_page(handle)
    app_status <- stop_app(app); active_app <<- NULL
    values <- vapply(points, `[[`, numeric(1), "value")
    slope <- least_squares_slope(seq_along(values), values)
    budget <- heap_budget_verdict(baseline$value, values[[30L]], slope)
    list(
      experiment = experiment, condition = condition, warmupCycles = warm,
      baseline = baseline, cycles = cycles, points = points,
      endBytes = values[[30L]], growthBytes = values[[30L]] - baseline$value,
      slopeBytesPerCycle = slope, budget = budget,
      allSettled = isTRUE(baseline$stable) && all(vapply(points, `[[`, logical(1), "stable")),
      finalRoundTrip = isTRUE(final_round_trip$ok), shinyConnected = connected,
      errors = errors, app = app_status
    )
  }
  heap <- list(D = list(), O = list())
  for (experiment in c("D", "O")) {
    for (condition in c("control", "candidate")) {
      heap[[experiment]][[condition]] <- run_heap_condition(experiment, condition)
    }
  }

  summarize_experiment <- function(pairs) {
    controls <- lapply(pairs, function(pair) pair$samples$control)
    candidates <- lapply(pairs, function(pair) pair$samples$candidate)
    deltas <- function(name) vapply(pairs, function(pair) as.numeric(pair$deltas[[name]]), numeric(1))
    raw <- function(side, name) vapply(if (identical(side, "control")) controls else candidates,
                                      function(sample) as.numeric(sample[[name]]), numeric(1))
    frame_delta <- deltas("frameP95Ms")
    preprocess_control <- raw("control", "preprocessMs")
    preprocess_candidate <- raw("candidate", "preprocessMs")
    dom_control <- raw("control", "domMilestoneMs")
    dom_candidate <- raw("candidate", "domMilestoneMs")
    callback_delta <- deltas("callbackToDomMs")
    server_callback_delta <- deltas("serverCallbackToDomMs")
    preprocess_p95_control <- nearest_rank(preprocess_control, 0.95)
    preprocess_p95_candidate <- nearest_rank(preprocess_candidate, 0.95)
    preprocess_tolerance <- max(preprocess_p95_control * 0.05, 1)
    all_samples <- c(controls, candidates)
    errors_zero <- all(vapply(all_samples, function(sample) {
      all(unlist(sample$errors, use.names = FALSE) == 0L)
    }, logical(1)))
    list(
      pairCount = length(pairs),
      frame = list(
        deltasMs = frame_delta, medianDeltaMs = nearest_rank(frame_delta, 0.5),
        p95DeltaMs = nearest_rank(frame_delta, 0.95), maxDeltaMs = max(deltas("frameMaxMs")),
        jankPairedP95 = nearest_rank(deltas("jankCount"), 0.95)
      ),
      preprocess = list(
        controlRawMs = preprocess_control, candidateRawMs = preprocess_candidate,
        controlP95Ms = preprocess_p95_control, candidateP95Ms = preprocess_p95_candidate,
        pairedP95DeltaMs = preprocess_p95_candidate - preprocess_p95_control,
        toleranceMs = preprocess_tolerance
      ),
      dom = list(
        controlRawMs = dom_control, candidateRawMs = dom_candidate,
        controlP95Ms = nearest_rank(dom_control, 0.95),
        candidateP95Ms = nearest_rank(dom_candidate, 0.95),
        pairedP95DeltaMs = nearest_rank(dom_candidate, 0.95) - nearest_rank(dom_control, 0.95)
      ),
      callback = list(
        boundary = "browser-custom-message-receive-to-semantic-dom",
        deltasMs = callback_delta, p95DeltaMs = nearest_rank(callback_delta, 0.95),
        serverBoundary = "r-handler-callback-epoch-to-semantic-dom",
        serverDeltasMs = server_callback_delta,
        serverP95DeltaMs = nearest_rank(server_callback_delta, 0.95)
      ),
      integrity = list(
        sameFixture = all(vapply(pairs, `[[`, logical(1), "sameFixture")),
        semanticHash = all(vapply(all_samples, function(sample)
          identical(sample$expectedSemanticSha256, sample$actualSemanticSha256), logical(1))),
        textMatch = all(vapply(all_samples, `[[`, logical(1), "textMatch")),
        quiet = all(vapply(all_samples, function(sample)
          sample$quietFrames >= 2L && sample$quietMs >= 100, logical(1))),
        scheduler = all(vapply(all_samples, `[[`, logical(1), "schedulerOk")),
        finalTool = all(vapply(all_samples, `[[`, logical(1), "finalTool")),
        shinyConnected = all(vapply(all_samples, `[[`, logical(1), "shinyConnected")),
        fallbackZero = !any(vapply(all_samples, `[[`, logical(1), "fallback")),
        errorsZero = errors_zero,
        appsExited = all(vapply(pairs, function(pair) isTRUE(pair$app$exited), logical(1)))
      )
    )
  }
  statistics <- lapply(measured, summarize_experiment)
  experiment_verdict <- lapply(statistics, function(stats) list(
    frame = stats$frame$p95DeltaMs <= 2 && stats$frame$maxDeltaMs <= 8 && stats$frame$jankPairedP95 <= 1,
    preprocess = stats$preprocess$pairedP95DeltaMs <= stats$preprocess$toleranceMs,
    dom = stats$dom$pairedP95DeltaMs <= 5,
    callback = stats$callback$p95DeltaMs <= 5,
    integrity = all(unlist(stats$integrity, use.names = FALSE))
  ))
  heap_verdict <- lapply(heap, function(experiment) {
    difference <- experiment$candidate$growthBytes - experiment$control$growthBytes
    list(
      control = isTRUE(experiment$control$allSettled) && isTRUE(experiment$control$budget$ok),
      candidate = isTRUE(experiment$candidate$allSettled) && isTRUE(experiment$candidate$budget$ok),
      treatmentControlGrowthDifferenceBytes = difference,
      differenceBudgetBytes = 4 * MIB,
      difference = is.finite(difference) && difference <= 4 * MIB,
      finalRoundTrip = isTRUE(experiment$control$finalRoundTrip) && isTRUE(experiment$candidate$finalRoundTrip),
      errorsZero = all(unlist(experiment$control$errors, use.names = FALSE) == 0L) &&
        all(unlist(experiment$candidate$errors, use.names = FALSE) == 0L),
      appsExited = isTRUE(experiment$control$app$exited) && isTRUE(experiment$candidate$app$exited)
    )
  })
  preflight_errors_zero <- all(unlist(preflight$errors, use.names = FALSE) == 0L)
  overall <- isTRUE(preflight$ok) && preflight_errors_zero && isTRUE(preflight$app$exited) &&
    all(vapply(experiment_verdict, function(item) all(unlist(item, use.names = FALSE)), logical(1))) &&
    all(vapply(heap_verdict, function(item) all(unlist(item[c("control", "candidate", "difference", "finalRoundTrip", "errorsZero", "appsExited")], use.names = FALSE)), logical(1)))

  artifact <- list(
    schemaVersion = 1L,
    gate = "plan123-section15-installed-browser",
    generatedUtc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    package = list(version = package_version, installedJsSha256 = installed_js_sha,
                   sourceJsSha256 = source_js_sha, identityMatch = TRUE),
    protocol = list(
      fixedSeed = FIXED_SEED, warmupPairs = WARMUP_PAIRS, measuredPairs = MEASURED_PAIRS,
      viewport = VIEWPORT, conditions = list(D = c("diagnostics-off", "diagnostics-on"),
                                             O = c("orb-hidden", "orb-shown")),
      measuredOrder = measured_orders, nearestRank = TRUE, outliersRemoved = FALSE,
      isolatedBrowserContexts = TRUE, freshHomePerPair = TRUE, sameBrowser = TRUE,
      visibleRequired = TRUE, fixtureRafSymmetric = TRUE
    ),
    capabilities = list(
      longTask = preflight$longTask$supported,
      heapProfilerCollectGarbage = TRUE, runtimeGetHeapUsage = TRUE,
      mutationObserver = TRUE, cryptoSubtleSha256 = TRUE
    ),
    caps = list(
      frameP95DeltaMs = 2, frameMaxDeltaMs = 8, jankPairedP95 = 1,
      markdownDomP95DeltaMs = 5, callbackDomP95DeltaMs = 5,
      heapGrowthBytes = 8 * MIB, heapSlopeBytesPerCycle = 0.25 * MIB,
      heapTreatmentControlGrowthDifferenceBytes = 4 * MIB
    ),
    preflight = preflight,
    warmup = warmups,
    measured = measured,
    heap = heap,
    statistics = statistics,
    verdict = list(experiments = experiment_verdict, heap = heap_verdict,
                   preflight = isTRUE(preflight$ok) && preflight_errors_zero,
                   overall = overall),
    privacy = list(chatContent = FALSE, home = FALSE, path = FALSE, environment = FALSE),
    process = list(activeChildren = 0L, cleanupRequested = TRUE)
  )
  artifact_dir <- file.path(project, ".kiro", "verification-logs", "plan126-performance",
                            format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"))
  dir.create(artifact_dir, recursive = TRUE, mode = "0700")
  artifact_path <- file.path(artifact_dir, "plan123-performance-verdict.json")
  writeLines(jsonlite::toJSON(artifact, auto_unbox = TRUE, pretty = TRUE, digits = NA), artifact_path, useBytes = TRUE)
  cat("PLAN123_ARTIFACT=", normalizePath(artifact_path, winslash = "/"), "\n", sep = "")
  for (experiment in c("D", "O")) {
    stats <- statistics[[experiment]]
    hv <- heap_verdict[[experiment]]
    cat(sprintf(
      "PLAN123_STATS experiment=%s pairs=%d frame_p95_delta_ms=%.3f frame_max_delta_ms=%.3f preprocess_p95_delta_ms=%.3f dom_p95_delta_ms=%.3f callback_p95_delta_ms=%.3f heap_control_growth_mib=%.3f heap_candidate_growth_mib=%.3f heap_delta_mib=%.3f\n",
      experiment, stats$pairCount, stats$frame$p95DeltaMs, stats$frame$maxDeltaMs,
      stats$preprocess$pairedP95DeltaMs, stats$dom$pairedP95DeltaMs,
      stats$callback$p95DeltaMs, heap[[experiment]]$control$growthBytes / MIB,
      heap[[experiment]]$candidate$growthBytes / MIB,
      hv$treatmentControlGrowthDifferenceBytes / MIB
    ))
  }
  cleanup_root()
  .cleanup_runner_owned_descendants()
  child_file <- sprintf("/proc/%d/task/%d/children", Sys.getpid(), Sys.getpid())
  read_children <- function() if (file.exists(child_file)) scan(child_file, what = integer(), quiet = TRUE) else integer()
  deadline <- Sys.time() + 2
  children <- read_children()
  while (length(children) && Sys.time() < deadline) {
    Sys.sleep(0.05)
    children <- read_children()
  }
  cat(sprintf("PLAN123_CLEANUP activeChildren=%d\n", length(children)))
  if (length(children)) stop("owned child processes remain after benchmark cleanup")
  cat("activeChildren=0\n")
  if (!overall) stop("Plan123 section 15 performance gate failed; see artifact")
  unlink(checkpoint_path, force = TRUE)
  cat("PLAN123_SECTION15_PERFORMANCE_GATE_PASS\n")
  invisible(artifact)
}

if (sys.nframe() == 0L) run_plan123_gate()
