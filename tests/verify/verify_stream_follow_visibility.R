#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
})
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".")
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  shared <- "/usrfiles/shared-projects/users/kaiping_yang/Rlibs/rstudio-addins/R-4.4"
  lib <- normalizePath(Sys.getenv("AUI_FOLLOW_LIBRARY", home))
  stopifnot(lib %in% c(home, shared))
  version <- as.character(packageVersion("shinyAssistantUI", lib.loc = lib))
  output <- Sys.getenv("AUI_FOLLOW_OUT", paste0(".kiro/verification-evidence/stream-follow-", version))
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  port <- httpuv::randomPort()
  root <- tempfile("stream-follow-investigation-")
  dir.create(root, mode = "0700")
  root <- normalizePath(root)
  stdout <- file.path(root, "app.out")
  stderr <- file.path(root, "app.err")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  app <- callr::r_bg(function(project, root, lib, home, port) {
    .libPaths(c(lib, home, .libPaths()))
    Sys.setenv(HOME = root, AUI_FOLLOW_LIBRARY = lib)
    setwd(project)
    library(shinyAssistantUI, lib.loc = lib)
    stopifnot(identical(normalizePath(find.package("shinyAssistantUI")), file.path(lib, "shinyAssistantUI")))
    shiny::runApp("tests/verify/stream_follow_visibility_app.R",
                  host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, root = root, lib = lib, home = home, port = port),
  stdout = stdout, stderr = stderr, user_profile = FALSE, system_profile = FALSE)
  ready <- FALSE
  for (i in seq_len(150L)) {
    if (!app$is_alive()) break
    ready <- file.exists(stderr) &&
      any(grepl("Listening on", readLines(stderr, warn = FALSE), fixed = TRUE))
    if (ready) break
    Sys.sleep(0.1)
  }
  if (!ready) stop(paste(readLines(stderr, warn = FALSE), collapse = "\n"), call. = FALSE)
  cat("FOLLOW_INSTALL ", lib, " VERSION=", version, "\n", sep = "")

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- ChromoteSession$new(width = 1000, height = 760)
  scene <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() scene)
  console_errors <- runtime_errors <- network_errors <- list()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- event
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    runtime_errors[[length(runtime_errors) + 1L]] <<- event
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors[[length(network_errors) + 1L]] <<- event
  })
  browser$Page$addScriptToEvaluateOnNewDocument(source = paste(
    readLines("tests/verify/fixtures/stream_follow_visibility.js", warn = FALSE), collapse = "\n"
  ))
  js <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(result$exceptionDetails)) {
      stop(result$exceptionDetails$exception$description, call. = FALSE)
    }
    result$result$value
  }
  screenshot_dir <- Sys.getenv("AUI_FOLLOW_SCREENSHOTS", "")
  screenshot_index <- 0L
  screenshot_next <- Sys.time()
  if (nzchar(screenshot_dir)) dir.create(screenshot_dir, recursive = TRUE, showWarnings = FALSE)
  capture_timed_screenshot <- function() {
    if (!nzchar(screenshot_dir) || Sys.time() < screenshot_next) return(invisible(NULL))
    ready <- tryCatch(isTRUE(js("!!document.querySelector('[data-slot=aui_thread-viewport]')")), error = function(e) FALSE)
    if (!ready) return(invisible(NULL))
    screenshot_index <<- screenshot_index + 1L
    screenshot_next <<- Sys.time() + 1
    stem <- sprintf("%s-%03d", scene, screenshot_index)
    browser$screenshot(
      file.path(screenshot_dir, paste0(stem, ".png")),
      selector = "[data-slot=aui_thread-viewport]"
    )
    state <- tryCatch(js("window.followProbe?.snapshot()||{ready:false}"), error = function(e) list(ready = FALSE))
    writeLines(as.character(jsonlite::toJSON(state, auto_unbox = TRUE, null = "null")),
               file.path(screenshot_dir, paste0(stem, ".json")))
  }
  wait <- function(code, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      capture_timed_screenshot()
      if (isTRUE(js(code))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() > deadline) {
        cat("FOLLOW_WAIT_STATE ", jsonlite::toJSON(js(
          "window.followProbe?.snapshot()||{ready:false}"
        ), auto_unbox = TRUE, null = "null"), "\n", sep = "")
        cat(tail(readLines(stderr, warn = FALSE), 12L), sep = "\n")
        stop("Follow investigation fixture did not reach: ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  key <- function(name, code, number) {
    for (type in c("keyDown", "keyUp")) {
      browser$Input$dispatchKeyEvent(type = type, key = name, code = code, windowsVirtualKeyCode = number)
    }
  }
  click <- function(selector) {
    point <- js(sprintf(
      "(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()",
      jsonlite::toJSON(selector, auto_unbox = TRUE)
    ))
    stopifnot(!is.null(point))
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  }
  scenes <- c("text-auto", "wheel-4", "wheel-40", "wheel-400",
              "tool-markdown", "reasoning-auto", "thinking-to-text", "canonical-replace",
              "keyboard-pageup", "scrollbar-drag")
  selected <- Sys.getenv("AUI_FOLLOW_SCENES", "")
  if (nzchar(selected)) {
    requested <- strsplit(selected, ",", fixed = TRUE)[[1L]]
    stopifnot(all(requested %in% scenes))
    scenes <- requested
  }
  summaries <- list()
  for (next_scene in scenes) {
    scene <- next_scene
    previous_document <- js("String(performance.timeOrigin)")
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/?scene=%s", port, scene))
    wait(sprintf(
      "String(performance.timeOrigin)!==%s&&document.readyState==='complete'&&!!window.followProbe&&window.__auiWindowErrorProbeReady===true&&document.body?.innerText.includes('Follow investigation history')",
      jsonlite::toJSON(previous_document, auto_unbox = TRUE)
    ))
    stopifnot(identical(js("document.querySelector('meta[name=follow-package-version]').content"), version))
    js("[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes('Follow investigation history')).querySelector('[data-slot=aui_thread-list-item-trigger]').click();true")
    wait("document.querySelector('[data-slot=aui_virtualized-messages]')?.dataset.messageCount==='90'")
    wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
    js("window.followProbe.start();document.querySelector('.aui-lexical-input').focus();true")
    browser$Input$insertText(text = scene)
    key("Enter", "Enter", 13L)
    wait("window.followProbe.snapshot().rendered>=1&&window.followProbe.snapshot().fixturePhase==='quiet-streaming'")
    Sys.sleep(0.2)
    before <- js("window.followProbe.snapshot()")
    after_input <- reading_anchor <- NULL
    if (startsWith(scene, "wheel-") || scene %in% c("canonical-replace", "keyboard-pageup", "scrollbar-drag")) {
      delta <- if (scene == "canonical-replace") {
        js("(()=>{const rows=[...document.querySelectorAll('[data-slot=aui_message-slot]')];return -rows.at(-1).getBoundingClientRect().height-350})()")
      } else if (startsWith(scene, "wheel-")) {
        -as.numeric(sub("wheel-", "", scene, fixed = TRUE))
      } else 0
      point <- js("(()=>{const r=document.querySelector('[data-slot=aui_thread-viewport]').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+Math.min(180,r.height/2)}})()")
      js("window.followProbe.mark('reader-input');true")
      if (scene == "keyboard-pageup") {
        browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
        browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
        key("PageUp", "PageUp", 33L)
      } else if (scene == "scrollbar-drag") {
        thumb <- js("(()=>{const e=document.querySelector('[data-slot=aui_thread-viewport]'),r=e.getBoundingClientRect();return {x:r.right-Math.max(2,(r.width-e.clientWidth)/2),y:r.bottom-20}})()")
        browser$Input$dispatchMouseEvent(type = "mousePressed", x = thumb$x, y = thumb$y,
                                        button = "left", buttons = 1L, clickCount = 1L)
        for (dy in c(40, 80, 120, 160)) {
          browser$Input$dispatchMouseEvent(type = "mouseMoved", x = thumb$x, y = thumb$y - dy,
                                          button = "left", buttons = 1L)
          Sys.sleep(0.03)
        }
        browser$Input$dispatchMouseEvent(type = "mouseReleased", x = thumb$x, y = thumb$y - 160,
                                        button = "left", buttons = 0L, clickCount = 1L)
      } else {
        browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
        browser$Input$dispatchMouseEvent(type = "mouseWheel", x = point$x, y = point$y, deltaX = 0, deltaY = delta)
      }
      Sys.sleep(0.25)
      after_input <- js("window.followProbe.snapshot()")
      reading_anchor <- js("window.followProbe.pickAnchor()")
      js("window.followProbe.mark('reading');true")
    }
    if (scene == "wheel-400") {
      wait("window.followProbe.snapshot().delivered>=12")
      js("window.followProbe.mark('explicit-resume');true")
      click(".aui-thread-scroll-to-bottom")
      wait("window.followProbe.snapshot().visible&&window.followProbe.snapshot().outerGap<=8")
      js("window.followProbe.mark('resumed');true")
    }
    wait("window.followProbe.snapshot().done===true", 18)
    if (scene == "canonical-replace") wait("window.followProbe.snapshot().fixturePhase==='canonical-replaced'")
    Sys.sleep(0.7)
    result <- js("window.followProbe.stop()")
    result$version <- version
    result$scene <- scene
    result$before <- before
    result$after_input <- after_input
    result$reading_anchor <- reading_anchor
    samples <- result$samples
    stable <- Filter(function(row) {
      isTRUE(row$ready) && !isTRUE(row$done) && row$rendered > 0 &&
        row$renderedAgeMs >= 50 && row$delivered >= 2
    }, samples)
    auto <- Filter(function(row) row$phase %in% c("auto", "resumed"), stable)
    reading <- Filter(function(row) identical(row$phase, "reading"), stable)
    last_reading <- if (length(reading)) reading[[length(reading)]] else NULL
    summary <- list(
      scene = scene, version = version, samples = length(samples),
      stable_auto_samples = length(auto),
      stable_auto_invisible = sum(vapply(auto, function(row) !isTRUE(row$visible), logical(1))),
      live_auto_tail_samples = sum(vapply(samples, function(row) {
        isTRUE(row$ready) && row$phase %in% c("auto", "resumed") && !isTRUE(row$done) &&
          !is.null(row$renderedTail$geometry)
      }, logical(1))),
      live_auto_tail_clipped = sum(vapply(samples, function(row) {
        isTRUE(row$ready) && row$phase %in% c("auto", "resumed") && !isTRUE(row$done) &&
          !is.null(row$renderedTail$geometry) && !isTRUE(row$renderedTail$geometry$visible)
      }, logical(1))),
      reading_samples = length(reading),
      initial_outer_gap = before$outerGap,
      after_input_outer_gap = after_input$outerGap,
      after_input_top_delta = if (!is.null(after_input)) after_input$outerTop - before$outerTop else NULL,
      last_reading_outer_gap = last_reading$outerGap,
      final = result$final,
      reading_anchor_initial = reading_anchor,
      final_anchor_drift = if (!is.null(reading_anchor) && !is.null(result$final$anchorTop))
        result$final$anchorTop - reading_anchor$top else NULL
    )
    if (scene %in% c("text-auto", "reasoning-auto", "thinking-to-text")) {
      stopifnot(summary$stable_auto_samples > 0L,
                summary$stable_auto_invisible == 0L,
                isTRUE(summary$final$visible), summary$final$outerGap <= 8)
    }
    if (identical(scene, "tool-markdown")) {
      tool_nodes <- unique(vapply(Filter(function(row) !is.null(row$tool$node), samples),
                                  function(row) row$tool$node, numeric(1)))
      stopifnot(summary$stable_auto_samples > 0L,
                summary$stable_auto_invisible == 0L,
                isTRUE(summary$final$visible), summary$final$inner$gap <= 2,
                length(tool_nodes) == 1L)
    }
    if (scene %in% c("wheel-4", "wheel-40", "canonical-replace",
                     "keyboard-pageup", "scrollbar-drag")) {
      stopifnot(summary$after_input_top_delta < 0,
                summary$reading_samples > 0L,
                abs(summary$final_anchor_drift) <= 2)
    }
    if (identical(scene, "wheel-400")) {
      stopifnot(isTRUE(summary$final$visible), summary$final$outerGap <= 8)
    }
    summaries[[length(summaries) + 1L]] <- summary
    cat("FOLLOW_SCENE ", as.character(jsonlite::toJSON(summary, auto_unbox = TRUE, null = "null")), "\n", sep = "")
    writeLines(as.character(jsonlite::toJSON(result, auto_unbox = TRUE, null = "null")),
               file.path(output, paste0(scene, ".json")))
  }
  report <- list(
    mode = "gate", version = version, scenes = summaries,
    console_errors = length(console_errors), runtime_errors = length(runtime_errors),
    window_errors = window_errors(), network_errors = length(network_errors)
  )
  writeLines(as.character(jsonlite::toJSON(report, auto_unbox = TRUE, null = "null", pretty = TRUE)),
             file.path(output, "summary.json"))
  cat("FOLLOW_GATE_DONE ", as.character(jsonlite::toJSON(list(
    mode = "gate", scenes = length(summaries),
    console = length(console_errors), runtime = length(runtime_errors),
    window = length(window_errors()), network = length(network_errors), output = output
  ), auto_unbox = TRUE)), "\n", sep = "")
  cleanup()
  stopifnot(length(console_errors) == 0L, length(runtime_errors) == 0L,
            length(window_errors()) == 0L, length(network_errors) == 0L)
}

main()
