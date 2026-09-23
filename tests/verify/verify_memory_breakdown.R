suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

verify_memory_breakdown <- function() {
  project <- normalizePath(".")
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  expected <- file.path(home_lib, "shinyAssistantUI")
  stopifnot(identical(normalizePath(find.package("shinyAssistantUI", lib.loc = home_lib)), expected))
  source(file.path(project, "tests/verify/owned_process_cleanup.R"), local = TRUE)
  source(file.path(project, "tests/verify/window_error_capture.R"), local = TRUE)
  root <- tempfile("aui-memory-breakdown-")
  dir.create(root, mode = "0700")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  stdout <- file.path(root, "app.out")
  stderr <- file.path(root, "app.err")
  read_log <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
  wait_until <- function(predicate, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(predicate())) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.05)
    }
  }
  checks <- 0L
  check <- function(name, passed) {
    cat(sprintf("[%s] %s\n", if (isTRUE(passed)) "PASS" else "FAIL", name))
    if (!isTRUE(passed)) stop(name, call. = FALSE)
    checks <<- checks + 1L
  }

  port <- httpuv::randomPort()
  app <- callr::r_bg(function(home_lib, root, port) {
    .libPaths(c(home_lib, .libPaths()))
    suppressPackageStartupMessages({
      library(shiny)
      library(shinyAssistantUI, lib.loc = home_lib)
    })
    cat("HOME_PACKAGE=", normalizePath(find.package("shinyAssistantUI")), "\n", sep = "")
    cat("VERSION=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
    ui <- bslib::page_fluid(
      tags$head(
        tags$link(rel = "icon", href = "data:,"),
        tags$style("html,body,.container-fluid{padding:0;margin:0}.verify-controls{height:44px;display:flex;align-items:center;gap:4px}")
      ),
      tags$div(
        class = "verify-controls",
        actionButton("cache", "Cache"), actionButton("anon", "Anon"),
        actionButton("missing", "Missing"), actionButton("zero", "Zero"),
        textOutput("stage", inline = TRUE)
      ),
      assistantUIOutput("chat", height = "calc(100vh - 44px)")
    )
    server <- function(input, output, session) {
      fixture <- tempfile("cgroup-", tmpdir = root)
      proc_root <- file.path(fixture, "proc")
      cgroup <- file.path(fixture, "cgroup")
      dir.create(file.path(proc_root, "4242"), recursive = TRUE)
      dir.create(cgroup)
      writeLines("VmRSS: 343040 kB", file.path(proc_root, "4242", "status"))
      writeLines(c("Rss: 343040 kB", "Pss: 307200 kB"),
                 file.path(proc_root, "4242", "smaps_rollup"))
      memory <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(
        shinyAssistantUI:::.memory_guard_default_config()
      )
      settings <- shinyAssistantUI:::.new_diagnostics_settings_addin_plugin(
        desired = FALSE, show_performance_orb = TRUE, launch_enabled = FALSE,
        environment_override = "none", launch_kind = "foreground"
      )
      stage <- reactiveVal("initial")
      output$stage <- renderText(stage())
      clock <- Sys.time() - 20
      record <- function(kind, hits = 12529) {
        clock <<- clock + 10
        gib <- 1024^3
        stat <- c(anon = 1.75 * gib, file = 26.25 * gib, inactive_file = 26 * gib,
                  shmem = 0, file_dirty = 0, file_writeback = 0)
        current <- 28 * gib
        limit <- 30 * gib
        psi <- 0.25
        if (identical(kind, "anon")) {
          stat[c("anon", "file", "inactive_file")] <- c(27, 1, 0.25) * gib
          psi <- 15
        } else if (identical(kind, "zero")) {
          current <- 0
          limit <- "max"
          stat[] <- 0
          psi <- 0
        }
        writeLines(format(current, scientific = FALSE), file.path(cgroup, "memory.current"))
        writeLines(format(limit, scientific = FALSE), file.path(cgroup, "memory.max"))
        writeLines(paste(names(stat), format(stat, scientific = FALSE, trim = TRUE)),
                   file.path(cgroup, "memory.stat"))
        writeLines(c(paste("max", hits), "oom 0", "oom_kill 0"),
                   file.path(cgroup, "memory.events"))
        writeLines(c(paste0("some avg10=", psi, " avg60=0 total=0"),
                     "full avg10=0.00 avg60=0 total=0"),
                   file.path(cgroup, "memory.pressure"))
        if (identical(kind, "missing")) {
          for (file in c("memory.current", "memory.max", "memory.stat",
                         "memory.events", "memory.pressure")) {
            writeLines(character(), file.path(cgroup, file))
          }
        }
        sample <- shinyAssistantUI:::.read_linux_memory_snapshot(
          pid = 4242L, proc_root = proc_root, cgroup_root = cgroup,
          now = function() clock
        )
        memory$observe(sample, "normal", "normal")
        stage(kind)
      }
      record("cache", 12526)
      record("cache")
      observeEvent(input$cache, record("cache"), ignoreInit = TRUE)
      observeEvent(input$anon, record("anon", 12535), ignoreInit = TRUE)
      observeEvent(input$missing, record("missing"), ignoreInit = TRUE)
      observeEvent(input$zero, record("zero", 0), ignoreInit = TRUE)

      handler <- function(message, on_chunk, on_done, ...) {
        on_chunk("MEMORY_LIVE_REPLY")
        on_done()
      }
      binding <- memory$bind(session, "chat_input")
      query <- parseQueryString(isolate(session$clientData$url_search))
      if (identical(query$protocol, "3")) binding$config$version <- 3L
      attr(handler, "ui_addons") <- list(
        memoryMonitor = binding$config,
        diagnosticsSettings = settings$bind(session, "chat_input")$config,
        diagnosticsLaunch = list(
          version = 2L, launchEnabled = FALSE, environmentOverride = "none",
          launchKind = "foreground", writerStartup = "off"
        )
      )
      history <- list(
        list(id = "history-user", role = "user", content = list(list(
          type = "text", text = "Memory history fixture"
        ))),
        list(id = "history-answer", role = "assistant", content = list(list(
          type = "text", text = "MEMORY_HISTORY_REPLY"
        ))),
        list(id = "history-tool", role = "assistant", content = list(list(
          type = "tool-call", toolCallId = "memory-history-tool", toolName = "Read",
          args = list(file_path = "/fixture/history.R"),
          argsText = as.character(jsonlite::toJSON(
            list(file_path = "/fixture/history.R"), auto_unbox = TRUE
          )),
          result = "MEMORY_HISTORY_TOOL_RESULT", isError = FALSE
        )))
      )
      api <- assistantUIServer(
        "chat", handler = handler, show_thread_list = TRUE, persistence = "server",
        on_session_load = function(session_id, thread_id, send_thread, ...) send_thread(history)
      )
      session$onFlushed(function() {
        api$send_sessions(list(sessions = list(list(
          id = "memory-history", title = "Memory history", createdAt = "2026-09-22T00:00:00Z"
        ))))
      }, once = TRUE)
      session$onSessionEnded(function() {
        memory$dispose()
        settings$dispose()
      })
    }
    shiny::runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(home_lib = home_lib, root = root, port = port),
  stdout = stdout, stderr = stderr, supervise = TRUE,
  env = c(R_LIBS_USER = home_lib, HOME = root))
  ready <- wait_until(function() app$is_alive() && any(grepl(
    "Listening on", read_log(stderr), fixed = TRUE
  )), 25)
  if (!ready) cat(paste(c(read_log(stdout), read_log(stderr)), collapse = "\n"), "\n")
  check("installed fixture is running and listening", ready)
  check("fixture loads the Home package", any(grepl(
    paste0("HOME_PACKAGE=", expected), read_log(stdout), fixed = TRUE
  )))

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- chromote::ChromoteSession$new(width = 1100, height = 900)
  phase <- "v4"
  window_errors <- capture_browser_window_errors(browser, function() phase)
  console_errors <- exceptions <- network_errors <- character()
  memory_frames <- 0L
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors <<- c(console_errors, "console error")
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    exceptions <<- c(exceptions, event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors <<- c(network_errors, event$errorText)
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- c(network_errors, "HTTP error")
  })
  browser$Network$webSocketFrameReceived(callback_ = function(event) {
    if (grepl("memory-monitor-sample", event$response$payloadData, fixed = TRUE))
      memory_frames <<- memory_frames + 1L
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_js <- function(js, timeout = 15) wait_until(function() isTRUE(value(js)), timeout)
  click <- function(selector) {
    point <- value(sprintf(paste0(
      "(()=>{const e=document.querySelector(%s);if(!e)return null;",
      "e.scrollIntoView({block:'nearest',inline:'nearest'});const r=e.getBoundingClientRect();",
      "const x=r.x+r.width/2,y=r.y+r.height/2,hit=document.elementFromPoint(x,y);",
      "if(r.width<=0||r.height<=0||x<0||y<0||x>innerWidth||y>innerHeight||!hit||!e.contains(hit))return null;",
      "return {x,y}})()"
    ), as.character(toJSON(selector, auto_unbox = TRUE))))
    if (is.null(point)) stop("Missing or obscured click target: ", selector)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
  }
  metric <- function(slot, attribute = "data-bytes") value(sprintf(
    "document.querySelector('[data-slot=\"%s\"]')?.getAttribute('%s')", slot, attribute
  ))
  refresh <- function() {
    previous <- memory_frames
    click("button[aria-label='Refresh backend memory']")
    received <- wait_until(function() {
      # A CDP round-trip pumps Chromote's child loop; Sys.sleep alone does not.
      value("true")
      memory_frames >= previous + 1L
    })
    if (!received || memory_frames != previous + 1L) {
      cat("REFRESH_EVIDENCE ", as.character(toJSON(list(
        before = previous, after = memory_frames, app_alive = app$is_alive(),
        browser = value(paste0(
          "(()=>{const b=document.querySelector('button[aria-label=\"Refresh backend memory\"]');",
          "return {input:Shiny.shinyapp.$inputValues.chat_input_memory_monitor_visible,",
          "buttonDisabled:b?.disabled,buttonText:b?.textContent,",
          "workingSet:document.querySelector('[data-slot=aui_session_working_set]')?.textContent,",
          "sampleTime:document.querySelector('[data-slot=aui_memory_cgroup_time]')?.dataset.timestamp,",
          "orbExpanded:document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.getAttribute('aria-expanded')}})()"
        )),
        console = console_errors, exceptions = exceptions, network = network_errors
      ), auto_unbox = TRUE, null = "null")), "\n", sep = "")
      cat(paste(tail(c(read_log(stdout), read_log(stderr)), 30L), collapse = "\n"), "\n")
    }
    check("Refresh accepts exactly one frame", received && memory_frames == previous + 1L)
  }
  panel_fits <- paste0(
    "(()=>{const orb=document.querySelector('[data-slot=aui_performance_orb]');",
    "const p=orb?.querySelector('[role=status]');if(!p)return false;",
    "const r=p.getBoundingClientRect(),h=orb.offsetParent.getBoundingClientRect();",
    "return r.width>0&&r.height>0&&r.top>=Math.max(0,h.top)&&r.left>=Math.max(0,h.left)",
    "&&r.bottom<=innerHeight&&r.right<=innerWidth})()"
  )
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  check("real widget mounts", wait_js("!!document.querySelector('.aui-lexical-input[contenteditable=true]')", 25))
  check("window error listener is active", isTRUE(value("window.__auiWindowErrorProbeReady===true")))
  check("history is listed", wait_js(
    "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>e.textContent.includes('Memory history'))"
  ))
  value("Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>e.textContent.includes('Memory history')).setAttribute('data-memory-history','true');true")
  click("[data-memory-history=true]")
  check("history text is restored", wait_js("document.body.innerText.includes('MEMORY_HISTORY_REPLY')"))
  value("document.querySelector('[data-slot=tool-group-trigger][aria-expanded=false]')?.click();true")
  check("historical tool is mounted", wait_js("!!document.querySelector('[data-slot=tool-fallback-trigger]')"))
  value("document.querySelector('[data-slot=tool-fallback-trigger][aria-expanded=false]')?.click();true")
  check("historical args stay renderable strings", wait_js(
    "document.querySelector('[data-slot=tool-fallback-root]')?.textContent.includes('/fixture/history.R')"
  ))
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "Memory live fixture")
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  check("real composer receives a live reply after restore", wait_js("document.body.innerText.includes('MEMORY_LIVE_REPLY')"))
  check("closed monitor has not pushed any frames", identical(memory_frames, 0L))

  click("button[aria-label='Performance diagnostics']")
  check("cache-heavy session estimates 2 GiB rather than raw 28 GiB", wait_until(function() {
    identical(metric("aui_session_working_set"), as.character(2 * 1024^3))
  }))
  check("v4 input envelope is exact", isTRUE(value(
    "(()=>{const v=Shiny.shinyapp.$inputValues.chat_input_memory_monitor_visible;return v.version===4&&v.sample===null&&Object.keys(v).length===6})()"
  )))
  check("raw, file and anonymous metrics are separate",
        identical(metric("aui_session_raw_usage"), as.character(28 * 1024^3)) &&
        identical(metric("aui_session_file"), as.character(26.25 * 1024^3)) &&
        identical(metric("aui_session_anon"), as.character(1.75 * 1024^3)))
  check("cumulative counts do not masquerade as interval pressure",
        identical(metric("aui_session_limit_events", "data-total"), "12529") &&
        identical(metric("aui_session_limit_events", "data-delta"), "3") &&
        identical(metric("aui_session_limit_events", "data-interval-ms"), "10000"))
  check("PSI and genuine zero values render", isTRUE(value(
    "document.querySelector('[data-slot=aui_session_stalls]').textContent.includes('some 0.25%')&&document.querySelector('[data-slot=aui_session_shmem]').textContent.includes('0 B')"
  )))
  check("panel fits the viewport", isTRUE(value(panel_fits)))
  frozen_frames <- memory_frames
  click("#anon")
  check("anonymous-heavy fixture observed", wait_js("document.getElementById('stage').textContent==='anon'"))
  Sys.sleep(0.2)
  check("observation leaves the open snapshot frozen", memory_frames == frozen_frames &&
          identical(metric("aui_session_working_set"), as.character(2 * 1024^3)))
  refresh()
  check("refresh distinguishes anonymous-heavy usage and PSI", wait_until(function() {
    identical(metric("aui_session_working_set"), as.character(27.75 * 1024^3)) &&
      identical(metric("aui_session_stalls", "data-some"), "15") &&
      identical(metric("aui_session_limit_events", "data-delta"), "6")
  }))
  sampled_at <- metric("aui_memory_cgroup_time", "data-timestamp")
  refresh()
  check("cached refresh preserves actual time and delta window",
        identical(metric("aui_memory_cgroup_time", "data-timestamp"), sampled_at) &&
        identical(metric("aui_session_limit_events", "data-delta"), "6") &&
        identical(metric("aui_session_limit_events", "data-interval-ms"), "10000"))

  click("#missing")
  check("missing-metrics fixture observed", wait_js("document.getElementById('stage').textContent==='missing'"))
  refresh()
  check("missing values are neither zero nor Unlimited", wait_js(
    "document.querySelector('[data-slot=aui_session_raw_usage]').textContent.includes('Unavailable / Unavailable')&&document.querySelector('[data-slot=aui_session_working_set]').textContent.includes('Unavailable')"
  ))
  click("#zero")
  check("zero-use fixture observed", wait_js("document.getElementById('stage').textContent==='zero'"))
  refresh()
  check("real zero differs from unavailable and max means Unlimited", wait_js(
    "document.querySelector('[data-slot=aui_session_raw_usage]').textContent.includes('0 B / Unlimited')&&document.querySelector('[data-slot=aui_session_working_set]').dataset.bytes==='0'"
  ))
  browser$Emulation$setDeviceMetricsOverride(
    width = 420L, height = 360L, deviceScaleFactor = 1, mobile = FALSE
  )
  check("expanded panel fits a narrow short Viewer", wait_js(panel_fits, 5))
  value("document.querySelector('[data-slot=aui_session_stalls]').scrollIntoView({block:'nearest'});true")
  check("pressure rows remain reachable by scrolling", isTRUE(value(
    "(()=>{const p=document.querySelector('[data-slot=aui_performance_orb] [role=status]'),r=document.querySelector('[data-slot=aui_session_stalls]').getBoundingClientRect();return p.scrollTop>0&&r.top>=0&&r.bottom<=innerHeight})()"
  )))
  click("button[aria-label='Performance diagnostics']")

  phase <- "v3"
  browser$Emulation$setDeviceMetricsOverride(
    width = 1100L, height = 900L, deviceScaleFactor = 1, mobile = FALSE
  )
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/?protocol=3", port))
  check("legacy client remounts", wait_js("!!document.querySelector('.aui-lexical-input[contenteditable=true]')", 25))
  click("button[aria-label='Performance diagnostics']")
  check("v3 continues to display its raw snapshot", wait_js(
    "document.querySelector('[data-slot=aui_session_raw_usage]')?.textContent.includes('28.00 GiB / 30.00 GiB')"
  ))
  check("legacy missing breakdown stays unavailable", isTRUE(value(
    "Shiny.shinyapp.$inputValues.chat_input_memory_monitor_visible.version===3&&document.querySelector('[data-slot=aui_session_working_set]').textContent.includes('Unavailable')&&document.querySelector('[data-slot=aui_session_stalls]').textContent.includes('some Unavailable')"
  )))
  check("zero browser console errors", length(console_errors) == 0L)
  check("zero runtime exceptions", length(exceptions) == 0L)
  check("zero direct window errors", length(window_errors()) == 0L)
  check("zero failed network requests", length(network_errors) == 0L)
  cat("BROWSER_RESULT checks=", checks,
      " console_errors=0 runtime_exceptions=0 window_errors=0 network_errors=0\n", sep = "")
}

verify_memory_breakdown()
