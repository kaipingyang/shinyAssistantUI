suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

verify_performance_observability <- function() {
  project <- normalizePath(".")
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  expected <- file.path(home_lib, "shinyAssistantUI")
  stopifnot(identical(normalizePath(find.package("shinyAssistantUI", lib.loc = home_lib)),
                      expected))
  source(file.path(project, "tests/verify/owned_process_cleanup.R"), local = TRUE)
  root <- tempfile("aui-performance-observability-")
  dir.create(root, mode = "0700")
  stdout <- file.path(root, "app.out")
  stderr <- file.path(root, "app.err")
  diagnostic_root <- file.path(root, ".claude_addin", "diagnostics")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
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
    cat("EVENT_MAX_BYTES=", shinyAssistantUI:::.normalize_diagnostics_config(TRUE)$event_max_bytes,
        "\n", sep = "")
    flush.console()
    proc_root <- file.path(root, "proc")
    cgroup <- file.path(root, "cgroup")
    status <- file.path(proc_root, "4242", "status")
    dir.create(dirname(status), recursive = TRUE)
    dir.create(cgroup)
    writeLines("VmRSS: 81920 kB", status)
    writeLines("2147483648", file.path(cgroup, "memory.current"))
    writeLines("10737418240", file.path(cgroup, "memory.max"))

    ui <- bslib::page_fluid(
      tags$head(
        tags$link(rel = "icon", href = "data:,"),
        tags$style("html,body,.container-fluid{padding:0;margin:0}.verify-controls{height:40px;display:flex;align-items:center;gap:12px}")
      ),
      tags$div(
        class = "verify-controls",
        actionButton("pressure", "Fixture pressure"),
        actionButton("freeze", "Freeze fixture sampling"),
        textOutput("sample_count", inline = TRUE),
        textOutput("gc_count", inline = TRUE),
        textOutput("guard_state", inline = TRUE)
      ),
      assistantUIOutput("chat", height = "calc(100vh - 40px)")
    )
    server <- function(input, output, session) {
      count <- reactiveVal(0L)
      collections <- reactiveVal(0L)
      level <- reactiveVal("normal")
      observations <- gc_calls <- 0L
      output$sample_count <- renderText(count())
      output$gc_count <- renderText(collections())
      output$guard_state <- renderText(level())
      config <- list(
        enabled = TRUE, soft_pss_bytes = 100 * 1024^2, hard_pss_bytes = 200 * 1024^2,
        soft_rss_bytes = 100 * 1024^2, hard_rss_bytes = 200 * 1024^2,
        consecutive_samples = 2L, active_interval = 0.2,
        idle_interval = 0.2, settle_delay = 0.15
      )
      memory <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(config)
      settings <- shinyAssistantUI:::.new_diagnostics_settings_addin_plugin(
        desired = TRUE, show_performance_orb = TRUE, launch_enabled = TRUE,
        environment_override = "none", launch_kind = "foreground"
      )
      diagnostics <- shinyAssistantUI:::.new_diagnostics_service(list(
        enabled = TRUE, directory = file.path(root, ".claude_addin", "diagnostics")
      ))
      stopifnot(identical(diagnostics$snapshot()$state, "started"))
      tracker <- shinyAssistantUI:::.new_memory_guard_gc_tracker(function() {
        gc_calls <<- gc_calls + 1L
        collections(gc_calls)
        gc(full = TRUE)
      })
      sampler <- shinyAssistantUI:::.new_linux_memory_guard_sampler(
        pid = 4242L, proc_root = proc_root, cgroup_root = cgroup, cgroup_every = 5L
      )
      guard <- shinyAssistantUI:::.new_memory_pressure_guard(
        sample = sampler, busy_snapshot = function() list(busy = FALSE),
        gc_full = tracker$collect, config = config,
        schedule = function(callback, delay) {
          timer <- later::later(callback, delay)
          function() shinyAssistantUI:::.cancel_later_timer(timer)
        },
        on_observation = function(sample, previous_state, next_state) {
          observations <<- observations + 1L
          count(observations)
          level(next_state)
          memory$observe(sample, previous_state, next_state)
          diagnostics$emit("memory_sample", c(
            list(guard_state = next_state, rss_bytes = sample$rss_bytes,
                 cgroup_current_bytes = sample$cgroup_current_bytes,
                 cgroup_max_bytes = sample$cgroup_max_bytes,
                 cgroup_limit = "limited"),
            tracker$snapshot()
          ))
        }
      )
      handler <- function(message, on_chunk, on_done, ...) {
        on_chunk("LIVE_RESPONSE_PRIVACY_SENTINEL")
        on_done()
      }
      attr(handler, "diagnostics_service") <- diagnostics
      attr(handler, "ui_addons") <- list(
        memoryMonitor = memory$bind(session, "chat_input")$config,
        diagnosticsSettings = settings$bind(session, "chat_input")$config,
        diagnosticsLaunch = list(
          version = 2L, launchEnabled = TRUE, environmentOverride = "none",
          launchKind = "foreground", writerStartup = "started"
        )
      )
      history <- list(
        list(id = "history-user", role = "user", content = list(list(
          type = "text", text = "HISTORY_PROMPT_PRIVACY_SENTINEL"
        ))),
        list(id = "history-answer", role = "assistant", content = list(list(
          type = "text", text = "HISTORY_RESPONSE_PRIVACY_SENTINEL"
        ))),
        list(id = "history-tool", role = "assistant", content = list(list(
          type = "tool-call", toolCallId = "HISTORY_TOOL_ID_PRIVACY_SENTINEL",
          toolName = "Read", args = list(file_path = "/private/HISTORY_PATH_PRIVACY_SENTINEL"),
          argsText = as.character(jsonlite::toJSON(
            list(file_path = "/private/HISTORY_PATH_PRIVACY_SENTINEL"), auto_unbox = TRUE
          )),
          result = "HISTORY_RESULT_PRIVACY_SENTINEL", isError = FALSE
        )))
      )
      api <- assistantUIServer(
        "chat", handler = handler, show_thread_list = TRUE, persistence = "server",
        on_session_load = function(session_id, thread_id, send_thread, ...) {
          send_thread(history)
        }
      )
      observeEvent(input$pressure, writeLines("VmRSS: 225280 kB", status), ignoreInit = TRUE)
      observeEvent(input$freeze, {
        guard$dispose()
        level("frozen")
      }, ignoreInit = TRUE)
      session$onFlushed(function() {
        api$send_sessions(list(sessions = list(list(
          id = "observability-history", title = "Observability history",
          createdAt = "2026-09-18T00:00:00Z"
        ))))
      }, once = TRUE)
      session$onSessionEnded(function() {
        guard$dispose()
        memory$dispose()
        settings$dispose()
        diagnostics$close()
      })
      guard$start()
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
  check("fresh R process loads HOME and the real 16 KiB default", any(grepl(
    paste0("HOME_PACKAGE=", expected), read_log(stdout), fixed = TRUE
  )) && any(grepl("EVENT_MAX_BYTES=16384", read_log(stdout), fixed = TRUE)))

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- chromote::ChromoteSession$new(width = 1100, height = 900)
  console_errors <- exceptions <- network_errors <- character()
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
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_js <- function(js, timeout = 15) wait_until(function() isTRUE(value(js)), timeout)
  click <- function(selector) {
    point <- value(sprintf(
      "(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()",
      as.character(jsonlite::toJSON(selector, auto_unbox = TRUE))
    ))
    if (is.null(point)) stop("Missing click target: ", selector)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
  }
  timestamp <- function(slot) value(sprintf(
    "Number(document.querySelector('[data-slot=\"%s\"]')?.dataset.timestamp || 0)", slot
  ))
  refresh <- function() {
    previous <- timestamp("aui_memory_refresh_time")
    Sys.sleep(0.02)
    click("button[aria-label='Refresh backend memory']")
    wait_until(function() timestamp("aui_memory_refresh_time") > previous)
  }
  rows <- function() {
    files <- list.files(diagnostic_root, pattern = "^diag-v1-.*\\.jsonl$", full.names = TRUE)
    lines <- unlist(lapply(files, read_log), use.names = FALSE)
    lapply(lines, function(line) tryCatch(
      jsonlite::fromJSON(line, simplifyVector = FALSE),
      error = function(error) list(invalid = TRUE)
    ))
  }
  has_event <- function(name) any(vapply(rows(), function(row) identical(row$event, name), logical(1)))
  browser$Page$navigate(paste0("http://127.0.0.1:", port))
  check("real widget mounts", wait_js("!!document.querySelector('.aui-lexical-input[contenteditable=true]')", 25))
  check("default frontend collector actually reaches canonical JSONL", wait_until(function() has_event("frontend_mount")))
  check("history is listed", wait_js(
    "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>e.textContent.includes('Observability history'))"
  ))
  value("Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>e.textContent.includes('Observability history')).setAttribute('data-observability-history','true'); true")
  click("[data-observability-history=true]")
  check("session-load restores historical text", wait_js("document.body.innerText.includes('HISTORY_RESPONSE_PRIVACY_SENTINEL')"))
  value("document.querySelector('[data-slot=tool-group-trigger][aria-expanded=false]')?.click();true")
  check("historical tool controls are mounted", wait_js("!!document.querySelector('[data-slot=tool-fallback-trigger]')"))
  value("document.querySelector('[data-slot=tool-fallback-trigger][aria-expanded=false]')?.click();true")
  check("historical tool args render without React object-child errors", wait_js(
    "document.querySelector('[data-slot=tool-fallback-root]')?.innerText.includes('HISTORY_PATH_PRIVACY_SENTINEL')"
  ))
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "LIVE_PROMPT_PRIVACY_SENTINEL")
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                               windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                               windowsVirtualKeyCode = 13L)
  check("real composer delivers a live reply after history restore", wait_js(
    "document.body.innerText.includes('LIVE_RESPONSE_PRIVACY_SENTINEL')"
  ))

  click("button[aria-label='Performance diagnostics']")
  check("memory v4 has a real timestamp", wait_until(function() timestamp("aui_memory_sample_time") > 0))
  check("v4 envelope remains exact", isTRUE(value(
    "(()=>{const v=Shiny.shinyapp.$inputValues.chat_input_memory_monitor_visible;return v.version===4&&v.sample===null&&Object.keys(v).length===6})()"
  )))
  check("performance panel is inside the viewport", isTRUE(value(
    "(()=>{const r=document.querySelector('[data-slot=aui_performance_orb] [role=status]').getBoundingClientRect();return r.top>=0&&r.left>=0&&r.bottom<=innerHeight&&r.right<=innerWidth})()"
  )))
  first_sample <- timestamp("aui_memory_sample_time")
  click("#pressure")
  check("fixture reaches post-GC hard idle", wait_js(
    "document.getElementById('gc_count').textContent==='1'&&document.getElementById('guard_state').textContent==='hard_idle'"
  ))
  after_gc <- value("Number(document.getElementById('sample_count').textContent)")
  check("at least three more observations arrive after GC", wait_js(sprintf(
    "Number(document.getElementById('sample_count').textContent)>=%s", after_gc + 3
  )))
  check("Refresh receives a newer actual sample after GC", refresh() &&
          timestamp("aui_memory_sample_time") > first_sample)
  check("tree and cgroup keep their independent cached sampling times",
        timestamp("aui_memory_tree_time") > 0 &&
        timestamp("aui_memory_tree_time") <= timestamp("aui_memory_sample_time") &&
        timestamp("aui_memory_cgroup_time") > 0 &&
        timestamp("aui_memory_cgroup_time") <= timestamp("aui_memory_sample_time"))

  click("#freeze")
  check("fixture sampling is explicitly frozen", wait_js("document.getElementById('guard_state').textContent==='frozen'"))
  check("frozen snapshot can still be requested", refresh())
  frozen <- timestamp("aui_memory_sample_time")
  age_before <- value("document.querySelector('[data-slot=aui_memory_sample_time]').textContent")
  Sys.sleep(1.2)
  check("cached refresh advances receipt time but never fabricates sample time", refresh() &&
          identical(timestamp("aui_memory_sample_time"), frozen))
  check("snapshot age advances while the panel stays open", wait_until(function() {
    !identical(value("document.querySelector('[data-slot=aui_memory_sample_time]').textContent"), age_before)
  }, 3))

  check("shared long-task source is measured, not an unknown zero", wait_js(
    "document.querySelector('[data-slot=aui_long_tasks]')?.dataset.state==='supported'"
  ))
  tasks <- value("Number(document.querySelector('[data-slot=aui_long_tasks]').dataset.count)")
  value("setTimeout(()=>{const end=performance.now()+180;while(performance.now()<end){}},0);true")
  check("controlled browser long task increments the visible counter", wait_js(sprintf(
    "Number(document.querySelector('[data-slot=aui_long_tasks]').dataset.count)>=%s", tasks + 1
  )))
  click("button[aria-label='Performance diagnostics']")
  check("frontend frame, heap and terminal summaries all reach the real writer", wait_until(function() {
    all(vapply(c("frame_summary", "page_js_heap_sample", "owned_commit_summary"), has_event, logical(1)))
  }))
  check("controlled long task also reaches canonical JSONL", wait_until(function() {
    any(vapply(rows(), function(row) identical(row$event, "longtask_summary") &&
      is.numeric(row$metrics$maxUs) && row$metrics$maxUs >= 150000, logical(1)))
  }))
  browser$Emulation$setDeviceMetricsOverride(
    width = 760L, height = 360L, deviceScaleFactor = 1, mobile = FALSE
  )
  click("button[aria-label='Performance diagnostics']")
  check("timestamp panel also fits a short RStudio-style viewer", wait_js(
    "(()=>{const orb=document.querySelector('[data-slot=aui_performance_orb]');const panel=orb?.querySelector('[role=status]');if(!panel)return false;const r=panel.getBoundingClientRect();const host=orb.offsetParent?.getBoundingClientRect();return r.top>=Math.max(0,host?.top||0)&&r.left>=Math.max(0,host?.left||0)&&r.bottom<=innerHeight&&r.right<=innerWidth})()", 3
  ))
  click("button[aria-label='Performance diagnostics']")
  final <- rows()
  check("canonical rows remain exact and well formed", length(final) > 0 &&
          all(vapply(final, function(row) identical(names(row), c("schema", "event", "ts", "metrics")), logical(1))))
  encoded <- as.character(jsonlite::toJSON(final, auto_unbox = TRUE))
  check("diagnostics contain none of the live/history/path/ID sentinels", !grepl("PRIVACY_SENTINEL|/private/", encoded))
  check("zero browser console errors", length(console_errors) == 0L)
  check("zero browser runtime exceptions", length(exceptions) == 0L)
  check("zero failed browser network requests", length(network_errors) == 0L)
  cat("BROWSER_RESULT checks=", checks, " console_errors=0 runtime_exceptions=0 network_errors=0\n", sep = "")
}

verify_performance_observability()
