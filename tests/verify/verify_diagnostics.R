#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

project <- normalizePath(getwd(), winslash = "/")
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
installed <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
failures <- character()
check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-62s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}
check(
  "driver resolves Home-installed package",
  identical(installed, file.path(home_library, "shinyAssistantUI")),
  installed
)

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu",
  "--disable-crash-reporter", "--disable-breakpad", "--noerrdialogs"
)))

start_app <- function(mode, home, port,
                      fixture = "diagnostics_protocol_app.R") {
  root <- file.path(home, ".claude_addin", "diagnostics")
  addin_project <- file.path(home, "addin-project")
  dir.create(addin_project, recursive = TRUE, mode = "0700", showWarnings = FALSE)
  stdout <- tempfile(sprintf("diagnostics-%s-out-", mode))
  stderr <- tempfile(sprintf("diagnostics-%s-err-", mode))
  process <- callr::r_bg(
    function(project, home_library, port, fixture) {
      .libPaths(c(home_library, .libPaths()))
      setwd(project)
      Sys.unsetenv("SHINYASSISTANTUI_DIAGNOSTICS_DIR")
      suppressPackageStartupMessages(library(shiny))
      shiny::runApp(
        file.path("tests", "verify", fixture),
        host = "127.0.0.1", port = port, launch.browser = FALSE
      )
    },
    args = list(project = project, home_library = home_library, port = port,
                fixture = fixture),
    env = c(
      HOME = home,
      R_LIBS_USER = home_library,
      SAU_DIAGNOSTICS_MODE = mode,
      SAU_DIAGNOSTICS_ROOT = root,
      SAU_ADDIN_PROJECT = addin_project,
      SAU_DIAGNOSTICS_ENV_SECRET = "ENV_CREDENTIAL_PRIVACY_SENTINEL"
    ),
    stdout = stdout,
    stderr = stderr,
    supervise = TRUE
  )
  deadline <- Sys.time() + 35
  repeat {
    err <- if (file.exists(stderr)) readLines(stderr, warn = FALSE) else character()
    if (any(grepl("Listening on", err, fixed = TRUE))) break
    if (!process$is_alive() || Sys.time() >= deadline) {
      cat(tail(err, 20), sep = "\n")
      stop("diagnostics fixture failed to boot: ", mode)
    }
    Sys.sleep(0.2)
  }
  list(process = process, stdout = stdout, stderr = stderr, home = home, root = root)
}

open_browser <- function(port) {
  browser <- ChromoteSession$new(width = 920, height = 850)
  chrome_process <- browser$parent$get_browser()$get_process()
  console_errors <- character()
  runtime_errors <- character()
  network_errors <- character()
  memory_frames <- character()
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(message) {
    if (identical(message$type, "error")) {
      console_errors <<- c(console_errors, "console.error")
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(message) {
    runtime_errors <<- c(runtime_errors, "runtime.exception")
  })
  browser$Network$loadingFailed(callback_ = function(message) {
    network_errors <<- c(network_errors, as.character(message$errorText %||% "loadingFailed"))
  })
  browser$Network$responseReceived(callback_ = function(message) {
    status <- suppressWarnings(as.numeric(message$response$status %||% 0))
    if (is.finite(status) && status >= 400) {
      network_errors <<- c(network_errors, paste0("HTTP ", status, " ", message$response$url %||% ""))
    }
  })
  browser$Network$webSocketFrameReceived(callback_ = function(message) {
    payload <- as.character(message$response$payloadData %||% "")
    if (grepl("memory-monitor-sample", payload, fixed = TRUE)) {
      memory_frames <<- c(memory_frames, payload)
    }
  })
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  list(
    browser = browser,
    chrome_process = chrome_process,
    memory_frame_count = function() length(memory_frames),
    memory_frame_text = function() paste(memory_frames, collapse = "\n"),
    errors = function() list(
      console = console_errors,
      runtime = runtime_errors,
      network = network_errors
    )
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
value <- function(browser, script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text %||% "browser evaluation failed")
  result$result$value
}
wait_for <- function(browser, script, timeout = 15, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(browser, script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
click_selector <- function(browser, selector) {
  encoded <- as.character(jsonlite::toJSON(selector, auto_unbox = TRUE))
  position <- value(browser, sprintf(
    paste0(
      "(function(){const e=document.querySelector(%s);if(!e)return null;",
      "e.scrollIntoView({block:'center',inline:'center'});",
      "const r=e.getBoundingClientRect();",
      "if(r.width<=0||r.height<=0||r.left<0||r.top<0||r.right>innerWidth||r.bottom>innerHeight)return null;",
      "const x=r.left+r.width/2,y=r.top+r.height/2,hit=document.elementFromPoint(x,y);",
      "if(!hit||!(hit===e||e.contains(hit)))return null;",
      "return JSON.stringify({x:x,y:y});})()"
    ),
    encoded
  ))
  if (is.null(position)) return(FALSE)
  point <- jsonlite::fromJSON(position)
  browser$Input$dispatchMouseEvent(
    type = "mousePressed", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  browser$Input$dispatchMouseEvent(
    type = "mouseReleased", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  TRUE
}
press_enter <- function(browser) {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}
close_browser <- function(handle) {
  invisible(try(handle$browser$close(), silent = TRUE))
  invisible(try(handle$chrome_process$kill_tree(), silent = TRUE))
  invisible(try(handle$chrome_process$kill(), silent = TRUE))
  invisible(try(handle$chrome_process$wait(timeout = 5000), silent = TRUE))
  Sys.sleep(0.4)
}
stop_app <- function(handle) {
  invisible(try(handle$process$kill_tree(), silent = TRUE))
  invisible(try(handle$process$kill(), silent = TRUE))
  invisible(try(handle$process$wait(timeout = 5000), silent = TRUE))
  for (index in seq_len(50L)) {
    if (!handle$process$is_alive()) break
    Sys.sleep(0.1)
  }
  !handle$process$is_alive()
}

# Phase 0: real HOME-installed addin host. This phase does not inject ui_addons
# or mock package internals; the production app-wide service snapshot is the
# sole source of diagnosticsLaunch.writerStartup.
addin_host_home <- tempfile("diagnostics-installed-addin-home-")
dir.create(addin_host_home, recursive = TRUE)
addin_host_port <- httpuv::randomPort()
addin_host_app <- start_app(
  "enabled", addin_host_home, addin_host_port,
  fixture = "diagnostics_installed_addin_host.R"
)
addin_host_browser <- open_browser(addin_host_port)
ah <- addin_host_browser$browser
check("installed addin host widget mounted", wait_for(
  ah, "!!document.querySelector('.aui-root')", 20
))
check("fixture is the real installed addin host", any(grepl(
  "fixture=installed-addin-host", readLines(addin_host_app$stdout, warn = FALSE),
  fixed = TRUE
)))
check("installed addin Settings opened", click_selector(
  ah, "button[aria-label='Settings']"
))
check("installed addin launch panel appears", wait_for(
  ah, "!!document.querySelector('[data-slot=aui_diagnostics_settings]')", 10
))
check("production launch truth reports actual service started", isTRUE(value(
  ah,
  paste0(
    "document.querySelector('input[aria-label=\"Save diagnostic logs\"]')?.checked===true&&",
    "document.querySelector('[data-slot=aui_diagnostics_settings]')?.innerText.includes('Logging started for this process.')"
  )
)))
Sys.sleep(0.5)
addin_host_errors <- addin_host_browser$errors()
close_browser(addin_host_browser)
check("installed addin host has zero console errors", length(addin_host_errors$console) == 0L)
check("installed addin host has zero runtime exceptions", length(addin_host_errors$runtime) == 0L)
check("installed addin host has zero network failures", length(addin_host_errors$network) == 0L,
      paste(addin_host_errors$network, collapse = " | "))
check("installed addin host process exits", stop_app(addin_host_app))

# Phase 1: protocol fixture with synthetic settings/memory transport. It retains
# history file_path/argsText, real composer, privacy and browser error coverage.
disabled_home <- tempfile("diagnostics-browser-disabled-home-")
dir.create(disabled_home, recursive = TRUE)
disabled_root <- file.path(disabled_home, ".claude_addin", "diagnostics")
disabled_app <- start_app("disabled", disabled_home, 9873L)
disabled_browser <- open_browser(9873L)
db <- disabled_browser$browser
check("disabled widget mounted", wait_for(db, "!!document.querySelector('.aui-root')", 20))
overflow_probe <- value(db, paste0(
  "JSON.stringify((()=>{const root=document.querySelector('.aui-root');",
  "const host=root?.parentElement;const rr=root?.getBoundingClientRect();",
  "const offenders=[...(root?.querySelectorAll('*')||[])].map(el=>{const r=el.getBoundingClientRect();",
  "return{tag:el.tagName,slot:el.getAttribute('data-slot'),cls:String(el.className||'').slice(0,120),",
  "left:Math.round(r.left),right:Math.round(r.right),width:Math.round(r.width),sw:el.scrollWidth,cw:el.clientWidth};})",
  ".filter(x=>rr&&(x.right>Math.ceil(rr.right)+1||x.left<Math.floor(rr.left)-1)).slice(0,12);",
  "const scrollers=[...(root?.querySelectorAll('*')||[])].map(el=>{const s=getComputedStyle(el);return{tag:el.tagName,",
  "slot:el.getAttribute('data-slot'),cls:String(el.className||'').slice(0,120),ox:s.overflowX,sw:el.scrollWidth,cw:el.clientWidth};})",
  ".filter(x=>x.sw>x.cw+1&&(x.ox==='auto'||x.ox==='scroll')).slice(0,12);",
  "return{docSW:document.documentElement.scrollWidth,docCW:document.documentElement.clientWidth,",
  "bodySW:document.body.scrollWidth,bodyCW:document.body.clientWidth,",
  "hostSW:host?.scrollWidth,hostCW:host?.clientWidth,rootSW:root?.scrollWidth,rootCW:root?.clientWidth,offenders,scrollers};})())"
))
overflow_data <- jsonlite::fromJSON(overflow_probe, simplifyVector = FALSE)
cat("[OVERFLOW_PROBE] ", overflow_probe, "\n", sep = "")
check("widget has no horizontal overflow", isTRUE(
  overflow_data$docSW <= overflow_data$docCW + 1 &&
    overflow_data$bodySW <= overflow_data$bodyCW + 1 &&
    overflow_data$hostSW <= overflow_data$hostCW + 1 &&
    overflow_data$rootSW <= overflow_data$rootCW + 1
), overflow_probe)
check("thread viewport owns no horizontal scrollbar", identical(
  value(db, "getComputedStyle(document.querySelector('[data-slot=aui_thread-viewport]')).overflowX"),
  "hidden"
))
Sys.sleep(0.8)
disabled_telemetry <- value(db,
  "Object.keys((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{}).filter(k=>k.includes('telemetry')).length")
check("disabled browser publishes no telemetry input", identical(as.integer(disabled_telemetry), 0L), disabled_telemetry)
check("memory sends nothing while Settings is closed", disabled_browser$memory_frame_count() == 0L)
check("Settings opened with diagnostics disabled", click_selector(db, "button[aria-label='Settings']"))
check("memory monitor entry appears", wait_for(db, "!!document.querySelector('button[aria-label=\"Memory monitor\"]')", 8))
check("memory monitor is initially collapsed", isFALSE(value(db,
  "document.querySelector('button[aria-label=\"Memory monitor\"]')?.getAttribute('aria-expanded') === 'true'")))
check("collapsed monitor has no visibility input", isTRUE(value(db,
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible'] === undefined")))
check("diagnostics settings controls appear", wait_for(db,
  "!!document.querySelector('[data-slot=aui_diagnostics_settings]')", 8))
check("diagnostics launch truth is restart-bound off", isTRUE(value(db,
  "document.querySelector('input[aria-label=\"Save diagnostic logs\"]')?.checked === false && document.querySelector('[data-slot=aui_diagnostics_settings]')?.innerText.includes('Logging was not requested')")))
check("Performance Orb is shown and initially collapsed", isTRUE(value(db,
  "document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.getAttribute('aria-expanded') === 'false'")))
check("settings ready uses exact v2 owner envelope", isTRUE(value(db,
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_settings_ready'];return v?.version===2&&v?.kind==='settings_ready'&&Number.isSafeInteger(v?.ownerId)&&v.ownerId>0&&Object.keys(v).length===3;})()")))
initial_settings_owner <- as.numeric(value(db,
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_settings_ready'].ownerId"))
check("memory monitor expanded", click_selector(db, "button[aria-label='Memory monitor']"))
check("memory monitor expanded in viewport", wait_for(db,
  "document.querySelector('button[aria-label=\"Memory monitor\"]')?.getAttribute('aria-expanded') === 'true'", 8))
check("expanded visibility reaches R with exact v2 envelope", wait_for(db,
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible'];return v?.version===2&&v?.visible===true&&v?.sample===null&&Object.keys(v).length===6;})()", 8))
check("first opening freezes latest collapsed observation", wait_for(db,
  "document.querySelector('[data-slot=aui_memory_monitor_content]')?.innerText.includes('PSS 25.0 MB')", 8))
check("memory v2 renders no history rows", identical(as.integer(value(db,
  "document.querySelectorAll('[data-slot=aui_memory_sample]').length")), 0L))
check("memory thresholds and guard state render", isTRUE(value(db,
  "document.querySelector('[data-slot=aui_memory_monitor_content]')?.innerText.includes('PSS soft 10.0 MB · hard 20.0 MB') && document.querySelector('[data-memory-state=hard]')?.textContent === 'High'")))
memory_panel_text <- value(db, "document.querySelector('[data-slot=aui_memory_monitor_content]')?.innerText || ''")
memory_privacy_sentinels <- c(
  "MEMORY_PID_PRIVACY_SENTINEL", "MEMORY_PATH_PRIVACY_SENTINEL",
  "MEMORY_CONTENT_PRIVACY_SENTINEL", "MEMORY_TIMESTAMP_PRIVACY_SENTINEL"
)
check("memory panel excludes PID/path/content/timestamp sentinels", !any(vapply(
  memory_privacy_sentinels, grepl, logical(1), x = memory_panel_text, fixed = TRUE
)))
visible_frames <- disabled_browser$memory_frame_count()
check("first opening receives exactly one frozen memory frame", identical(visible_frames, 1L), visible_frames)
check("memory monitor collapsed", click_selector(db, "button[aria-label='Memory monitor']"))
check("collapsed visibility reaches R", wait_for(db,
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible']?.visible === false", 8))
Sys.sleep(0.8)
check("collapsed observation 26 produces no browser push",
      identical(disabled_browser$memory_frame_count(), visible_frames),
      disabled_browser$memory_frame_count())
check("memory monitor reopened", click_selector(db, "button[aria-label='Memory monitor']"))
check("reopen receives latest sample 26", wait_for(db,
  "document.querySelector('[data-slot=aui_memory_monitor_content]')?.innerText.includes('PSS 26.0 MB')", 8))
check("reopen adds exactly one WebSocket memory frame",
      identical(disabled_browser$memory_frame_count(), visible_frames + 1L),
      disabled_browser$memory_frame_count())
initial_memory_owner <- as.numeric(value(db,
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible'].ownerId"))
frame_text <- disabled_browser$memory_frame_text()
check("memory transport excludes PID/path/content/timestamp sentinels", !any(vapply(
  memory_privacy_sentinels, grepl, logical(1), x = frame_text, fixed = TRUE
)))
check("Orb setting CAS hides Orb immediately", click_selector(db, "input[aria-label='Show Performance Orb']"))
check("Orb canonical broadcast unmounts control", wait_for(db,
  "!document.querySelector('button[aria-label=\"Performance diagnostics\"]')", 8))
check("first settings owner completed request 1", isTRUE(value(db, sprintf(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_setting'];return v?.ownerId===%s&&v?.requestId===1;})()",
  initial_settings_owner
))))
check("Orb setting CAS shows Orb again", click_selector(db, "input[aria-label='Show Performance Orb']"))
check("Orb remounts collapsed", wait_for(db,
  "document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.getAttribute('aria-expanded') === 'false'", 8))
check("first settings owner completed request 2", isTRUE(value(db, sprintf(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_setting'];return v?.ownerId===%s&&v?.requestId===2;})()",
  initial_settings_owner
))))

check("chat output remount triggered by a real button", click_selector(db, "#remount_chat"))
check("chat output is removed before reinsertion", wait_for(db, "!document.querySelector('.aui-root')", 4))
check("chat output remounts", wait_for(db, "!!document.querySelector('.aui-root')", 12))
check("settings remount receives a fresh R-issued owner", wait_for(db, sprintf(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_settings_ready'];return v?.version===2&&v?.kind==='settings_ready'&&v?.ownerId>%s&&Object.keys(v).length===3;})()",
  initial_settings_owner
), 8))
rebound_settings_owner <- as.numeric(value(db,
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_settings_ready'].ownerId"))
check("Settings reopens after output remount", click_selector(db, "button[aria-label='Settings']"))
check("remounted settings controls appear", wait_for(db,
  "!!document.querySelector('[data-slot=aui_diagnostics_settings]')", 8))
check("remounted memory monitor opens", click_selector(db, "button[aria-label='Memory monitor']"))
check("memory remount uses a higher owner accepted by R", wait_for(db, sprintf(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible'];return v?.version===2&&v?.visible===true&&v?.ownerId>%s&&v?.openId===1&&v?.sample===null;})()",
  initial_memory_owner
), 8))
check("memory remount still receives the latest frozen snapshot", wait_for(db,
  "document.querySelector('[data-slot=aui_memory_monitor_content]')?.innerText.includes('PSS 26.0 MB')", 8))
check("post-remount settings CAS hides Orb", click_selector(db, "input[aria-label='Show Performance Orb']"))
check("post-remount request resets to request 1 on the new owner", wait_for(db, sprintf(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_diagnostics_setting'];return v?.ownerId===%s&&v?.requestId===1&&v?.field==='showPerformanceOrb'&&v?.value===false;})()",
  rebound_settings_owner
), 8))
check("post-remount canonical broadcast unmounts Orb", wait_for(db,
  "!document.querySelector('button[aria-label=\"Performance diagnostics\"]')", 8))
check("post-remount settings CAS remains usable", click_selector(db, "input[aria-label='Show Performance Orb']"))
check("post-remount Orb returns collapsed", wait_for(db,
  "document.querySelector('button[aria-label=\"Performance diagnostics\"]')?.getAttribute('aria-expanded') === 'false'", 8))
value(db, "document.getElementById('chat')?.remove(); true")
Sys.sleep(0.5)
disabled_errors <- disabled_browser$errors()
close_browser(disabled_browser)
Sys.sleep(1)
check("disabled diagnostics creates no directory", !dir.exists(disabled_root), disabled_root)
check("disabled browser has zero console errors", length(disabled_errors$console) == 0L)
check("disabled browser has zero runtime exceptions", length(disabled_errors$runtime) == 0L)
check("disabled browser has zero network failures", length(disabled_errors$network) == 0L,
      paste(disabled_errors$network, collapse = " | "))
check("disabled app process exits", stop_app(disabled_app))

# Phase 2: enabled default path, historical restore, and a real CDP composer submission.
enabled_home <- tempfile("diagnostics-browser-enabled-home-")
dir.create(enabled_home, recursive = TRUE)
enabled_root <- file.path(enabled_home, ".claude_addin", "diagnostics")
old_root <- file.path(enabled_home, ".local", "state", "shinyAssistantUI", "diagnostics")
dir.create(old_root, recursive = TRUE)
old_sentinel <- file.path(old_root, "legacy-sentinel.jsonl")
writeLines("LEGACY_DIAGNOSTICS_SENTINEL", old_sentinel, useBytes = TRUE)
old_listing_before <- list.files(old_root, all.files = TRUE, no.. = TRUE)
old_md5_before <- unname(tools::md5sum(old_sentinel))
old_info_before <- file.info(old_sentinel)[, c("size", "mode", "mtime"), drop = FALSE]
enabled_app <- start_app("enabled", enabled_home, 9874L)
enabled_browser <- open_browser(9874L)
b <- enabled_browser$browser
check("enabled widget mounted", wait_for(b, "!!document.querySelector('.aui-root')", 20))
check("history session appears", wait_for(
  b,
  "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.textContent||'').includes('Diagnostics history'))",
  15
))
value(b,
  "(function(){const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(x=>(x.textContent||'').includes('Diagnostics history'));if(!e)return false;e.setAttribute('data-diagnostics-history','true');return true;})()"
)
check("history session clicked", click_selector(b, "[data-diagnostics-history='true']"))
check("historical prompt restored", wait_for(b, "document.body.innerText.includes('HISTORY_PROMPT_PRIVACY_SENTINEL')", 12))
check("historical response restored", wait_for(b, "document.body.innerText.includes('HISTORY_RESPONSE_PRIVACY_SENTINEL')", 12))
value(b, "document.querySelector('[data-slot=tool-group-trigger]')?.click(); document.querySelector('[data-slot=tool-fallback-trigger]')?.click(); true")
check("historical tool card rendered", wait_for(b, "!!document.querySelector('[data-slot=tool-fallback-root]')", 8))

check("real composer focused", click_selector(b, ".aui-lexical-input[contenteditable='true']"))
b$Input$insertText(text = "LIVE_PROMPT_PRIVACY_SENTINEL")
press_enter(b)
check("live prompt rendered", wait_for(b, "document.body.innerText.includes('LIVE_PROMPT_PRIVACY_SENTINEL')", 10))
check("live response rendered", wait_for(b, "document.body.innerText.includes('LIVE_RESPONSE_PRIVACY_SENTINEL')", 15))

check("historical file_path argsText renders as text", wait_for(b,
  "document.querySelector('[data-slot=tool-fallback-root]')?.innerText.includes('HISTORY_PATH_PRIVACY_SENTINEL') && document.querySelector('[data-slot=tool-fallback-root]')?.innerText.includes('HISTORY_TOOL_ARGS_PRIVACY_SENTINEL')", 8))
Sys.sleep(1.2)
enabled_telemetry <- value(b,
  "Object.keys((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{}).filter(k=>k.includes('telemetry')).length")
check("enabled browser publishes telemetry input", as.integer(enabled_telemetry) >= 1L, enabled_telemetry)

# Trigger React unmount while Shiny's websocket is still alive, allowing one final batch.
value(b, "document.getElementById('chat')?.remove(); true")
Sys.sleep(1.0)
enabled_errors <- enabled_browser$errors()
close_browser(enabled_browser)

cleanup_seen <- FALSE
for (index in seq_len(80L)) {
  files <- if (dir.exists(enabled_root)) list.files(enabled_root, full.names = TRUE) else character()
  if (length(files)) {
    text <- paste(vapply(files, function(path) {
      paste(readLines(path, warn = FALSE), collapse = "\n")
    }, character(1)), collapse = "\n")
    if (grepl('"event":"storage_outcome"', text, fixed = TRUE) &&
        grepl('"operation":"close"', text, fixed = TRUE)) {
      cleanup_seen <- TRUE
      break
    }
  }
  Sys.sleep(0.1)
}
check("server session finalizer writes canonical close outcome", cleanup_seen)
check("enabled app process exits", stop_app(enabled_app))

check("diagnostics default path is under addin Settings root",
      identical(enabled_root, file.path(enabled_home, ".claude_addin", "diagnostics")),
      enabled_root)
old_listing_after <- list.files(old_root, all.files = TRUE, no.. = TRUE)
old_md5_after <- unname(tools::md5sum(old_sentinel))
old_info_after <- file.info(old_sentinel)[, c("size", "mode", "mtime"), drop = FALSE]
check("legacy diagnostics listing is unchanged", identical(old_listing_after, old_listing_before))
check("legacy diagnostics sentinel hash is unchanged", identical(old_md5_after, old_md5_before))
check("legacy diagnostics sentinel metadata is unchanged", identical(old_info_after, old_info_before))
check("legacy diagnostics sentinel content is unchanged",
      identical(readLines(old_sentinel, warn = FALSE), "LEGACY_DIAGNOSTICS_SENTINEL"))
check("legacy sentinel was not copied into new diagnostics",
      !any(grepl("LEGACY_DIAGNOSTICS_SENTINEL", unlist(lapply(
        list.files(enabled_root, full.names = TRUE), readLines, warn = FALSE
      )), fixed = TRUE)))

jsonl_files <- list.files(
  enabled_root, pattern = "\\.jsonl(\\.[0-9]+)?$", full.names = TRUE
)
check("enabled diagnostics creates bounded JSONL", length(jsonl_files) >= 1L && length(jsonl_files) <= 2L,
      paste(basename(jsonl_files), collapse = ", "))
all_lines <- character()
for (path in jsonl_files) {
  size <- file.info(path)$size
  bytes <- readBin(path, what = "raw", n = size)
  text <- rawToChar(bytes)
  check(paste0("JSONL file ends in newline: ", basename(path)), endsWith(text, "\n"))
  lines <- strsplit(text, "\n", fixed = TRUE)[[1L]]
  all_lines <- c(all_lines, lines[nzchar(lines)])
}
rows <- lapply(all_lines, jsonlite::fromJSON, simplifyVector = FALSE)
events <- vapply(rows, `[[`, character(1), "event")
check("every row has exact canonical common fields", all(vapply(
  rows, function(row) identical(names(row), c("schema", "event", "ts", "metrics")) &&
    identical(row$schema, 1L) && is.numeric(row$ts) && length(row$ts) == 1L &&
    is.finite(row$ts) && row$ts >= 0 && row$ts == floor(row$ts) && is.list(row$metrics),
  logical(1)
)))
check("frontend mount and unmount persisted", all(c("frontend_mount", "frontend_unmount") %in% events),
      paste(unique(events[grepl("frontend", events)]), collapse = ","))
run_phases <- vapply(rows[events == "run_state"], function(row) row$metrics$phase, character(1))
check("backend admitted and completed live turn canonically", all(c("queued", "complete") %in% run_phases),
      paste(unique(run_phases), collapse = ","))
storage_operations <- vapply(rows[events == "storage_outcome"], function(row) row$metrics$operation, character(1))
check("backend startup and close outcomes persisted canonically", all(c("startup", "close") %in% storage_operations),
      paste(unique(storage_operations), collapse = ","))
check("canonical rows contain no legacy correlation fields", all(vapply(
  rows,
  function(row) !any(c("source", "generation", "session", "thread_hash", "run_hash",
                       "threadId", "runId", "pid") %in% names(row)),
  logical(1)
)))

serialized <- paste(all_lines, collapse = "\n")
privacy_sentinels <- c(
  "LIVE_PROMPT_PRIVACY_SENTINEL", "LIVE_RESPONSE_PRIVACY_SENTINEL",
  "HISTORY_PROMPT_PRIVACY_SENTINEL", "HISTORY_RESPONSE_PRIVACY_SENTINEL",
  "HISTORY_TOOL_ARGS_PRIVACY_SENTINEL", "HISTORY_TOOL_RESULT_PRIVACY_SENTINEL",
  "HISTORY_PATH_PRIVACY_SENTINEL", "RAW_TOOL_ID_PRIVACY_SENTINEL",
  "RAW_SESSION_ID_PRIVACY_SENTINEL", "RAW_STDERR_PRIVACY_SENTINEL",
  "ENV_CREDENTIAL_PRIVACY_SENTINEL", "MEMORY_PID_PRIVACY_SENTINEL",
  "MEMORY_PATH_PRIVACY_SENTINEL", "MEMORY_CONTENT_PRIVACY_SENTINEL",
  "MEMORY_TIMESTAMP_PRIVACY_SENTINEL", project
)
leaked <- privacy_sentinels[vapply(
  privacy_sentinels, function(sentinel) grepl(sentinel, serialized, fixed = TRUE), logical(1)
)]
check("JSONL excludes live/history/content/path/env/stderr/raw-ID sentinels", length(leaked) == 0L,
      paste(leaked, collapse = ", "))
check("enabled browser has zero console errors", length(enabled_errors$console) == 0L)
check("enabled browser has zero runtime exceptions", length(enabled_errors$runtime) == 0L)
check("enabled browser has zero network failures", length(enabled_errors$network) == 0L,
      paste(enabled_errors$network, collapse = " | "))

unlink(c(addin_host_home, disabled_home, enabled_home), recursive = TRUE, force = TRUE)

cleanup_owned_processx_helpers <- function() {
  child_file <- sprintf("/proc/%d/task/%d/children", Sys.getpid(), Sys.getpid())
  matching <- function() {
    if (!file.exists(child_file)) return(integer())
    children <- scan(child_file, quiet = TRUE)
    children[vapply(children, function(pid) {
      cmdline <- sprintf("/proc/%d/cmdline", pid)
      if (!file.exists(cmdline)) return(FALSE)
      bytes <- tryCatch(readBin(cmdline, "raw", 100000L), error = function(error) raw())
      bytes[bytes == as.raw(0)] <- charToRaw(" ")
      grepl("/processx/bin/supervisor", rawToChar(bytes), fixed = TRUE)
    }, logical(1))]
  }
  owned <- matching()
  for (pid in owned) invisible(try(tools::pskill(pid, tools::SIGTERM), silent = TRUE))
  for (index in seq_len(50L)) {
    if (!length(matching())) return(TRUE)
    Sys.sleep(0.05)
  }
  FALSE
}

check("owned processx helpers exit before driver", cleanup_owned_processx_helpers())
if (length(failures)) stop("diagnostics browser verification failed: ", paste(failures, collapse = ", "))
cat("DIAGNOSTICS_BROWSER_VERIFY_DONE\n")
