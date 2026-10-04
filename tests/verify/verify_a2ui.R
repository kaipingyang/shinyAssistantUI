#!/usr/bin/env Rscript
suppressPackageStartupMessages({ library(callr); library(chromote) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".")
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  port <- httpuv::randomPort()
  logs <- c(tempfile("a2ui-out-"), tempfile("a2ui-err-"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(project, home, port) {
    .libPaths(c(home, .libPaths())); setwd(project)
    library(shinyAssistantUI, lib.loc = home)
    stopifnot(packageVersion("shinyAssistantUI") == "0.5.7.9016")
    shiny::runApp("tests/verify/a2ui_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, home = home, port = port),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(160L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 900, height = 820)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- network_errors <- list()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) if (identical(event$type, "error")) console_errors[[length(console_errors)+1L]] <<- event)
  browser$Runtime$exceptionThrown(callback_ = function(event) runtime_errors[[length(runtime_errors)+1L]] <<- event)
  browser$Network$loadingFailed(callback_ = function(event) if (!isTRUE(event$canceled)) network_errors[[length(network_errors)+1L]] <<- event)
  value <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait <- function(code, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(code), error = function(e) FALSE))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() >= deadline) {
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 30), sep = "\n")
        cat("\nA2UI_DOM_STATE\n", tryCatch(value("document.body.innerText"), error = function(e) "<unavailable>"), "\n")
        cat("A2UI_HIDDEN_STATE ", tryCatch(value("JSON.stringify({actions:document.getElementById('actions')?.textContent,validation:document.getElementById('validation_error')?.textContent,context:document.getElementById('action_context')?.textContent,control:document.getElementById('control_error')?.textContent})"), error = function(e) "<unavailable>"), "\n", sep = "")
        stop("Timed out: ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  click <- function(selector) {
    point <- value(sprintf("(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", jsonlite::toJSON(selector, auto_unbox = TRUE)))
    stopifnot(!is.null(point))
    browser$Input$dispatchMouseEvent(type="mousePressed", x=point$x, y=point$y, button="left", clickCount=1L)
    browser$Input$dispatchMouseEvent(type="mouseReleased", x=point$x, y=point$y, button="left", clickCount=1L)
  }
  key <- function() {
    browser$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
    browser$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
  }
  click_button <- function(label) {
    point <- value(sprintf("(()=>{const e=[...document.querySelectorAll('[data-aui=button]')].find(x=>x.textContent.includes(%s));if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", jsonlite::toJSON(label, auto_unbox = TRUE)))
    stopifnot(!is.null(point))
    browser$Input$dispatchMouseEvent(type="mousePressed", x=point$x, y=point$y, button="left", clickCount=1L)
    browser$Input$dispatchMouseEvent(type="mouseReleased", x=point$x, y=point$y, button="left", clickCount=1L)
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
  stage <- "create"
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "show a2ui")
  key()
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceRevision==='4'")
  wait("document.querySelector('[data-aui=button]')?.textContent.includes('Confirm A2UI')")
  wait("document.querySelector('input[data-aui=input]')?.value==='Ada'")
  wait("document.body.innerText.includes('Ready A2UI')&&document.body.innerText.includes('First item')&&document.body.innerText.includes('Second item')")
  stopifnot(!isTRUE(value("document.body.innerText.includes('IGNORED ACTIVITY')")))
  wait("document.getElementById('control_error').textContent.includes('active matching run')&&document.getElementById('control_error').textContent.includes('stale bucket cleared')")
  stopifnot(!isTRUE(value("!!document.querySelector('[data-surface-id=post-done-control-surface]')")))
  stopifnot(value("document.querySelectorAll('[data-slot=aui_a2ui_surface]').length") == 1)


  stage <- "local-open-url"
  stopifnot(isTRUE(value("window.__a2uiOpened=[];window.open=(url,target,features)=>{window.__a2uiOpened.push({url,target,features});return null};true")))
  click_button("Open safe URL")
  wait("window.__a2uiOpened.length===1&&window.__a2uiOpened[0].url==='https://example.com/docs'&&window.__a2uiOpened[0].target==='_blank'&&window.__a2uiOpened[0].features==='noopener,noreferrer'")
  click_button("Open unsafe URL")
  Sys.sleep(0.2)
  stopifnot(value("window.__a2uiOpened.length") == 1)
  stopifnot(value("document.getElementById('actions').textContent.trim()") == "0")
  stage <- "local-edit"
  click("input[data-aui=input]")
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "a", code = "KeyA", modifiers = 2L,
    windowsVirtualKeyCode = 65L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "a", code = "KeyA", modifiers = 2L,
    windowsVirtualKeyCode = 65L
  )
  browser$Input$insertText(text = "Grace")
  wait("document.querySelector('input[data-aui=input]')?.value==='Grace'")
  wait("document.body.innerText.includes('Grace')")

  stage <- "action-update"
  click_button("Confirm A2UI")
  wait("(()=>{try{const x=JSON.parse(document.getElementById('validation_error').textContent);return x.code==='VALIDATION_FAILED'&&x.surfaceId==='fixture-surface'&&x.path==='/operations'&&x.beforeSequence===4}catch{return false}})()")
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceRevision==='5'")
  wait("document.querySelector('[data-aui=button]')?.textContent.includes('Updated A2UI')")
  wait("document.body.innerText.includes('Server updated')")
  wait("document.querySelector('input[data-aui=input]')?.value==='Grace'")
  wait("document.getElementById('actions').textContent.trim()==='1'")
  wait("(()=>{try{const x=JSON.parse(document.getElementById('action_context').textContent);return x.formId==='fixture-form'&&x.values.name==='Grace'&&x.values.accepted===false}catch{return false}})()")

  stage <- "action-delete"
  click_button("Updated A2UI")
  wait("!document.querySelector('[data-slot=aui_a2ui_surface]')")
  wait("document.getElementById('actions').textContent.trim()==='2'")

  stage <- "legacy-history-load"
  stopifnot(isTRUE(value("(()=>{const r=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes('A2UI Legacy History'));const b=r?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!b)return false;b.click();return true})()")))
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceId==='history-surface'")
  wait("document.body.innerText.includes('Historical A2UI from snapshot')")
  stopifnot(!isTRUE(value("document.body.innerText.includes('POISONED LEGACY DERIVED SPEC')")))

  stage <- "present-history-load"
  stopifnot(isTRUE(value("(()=>{const r=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes('A2UI Present History'));const b=r?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!b)return false;b.click();return true})()")))
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceId==='history-surface'")
  wait("document.body.innerText.includes('Historical A2UI from snapshot')")
  stopifnot(!isTRUE(value("document.body.innerText.includes('POISONED PRESENT DERIVED SPEC')")))

  stopifnot(length(console_errors)==0L, length(runtime_errors)==0L,
            length(window_errors())==0L, length(network_errors)==0L)
  cat("A2UI_BROWSER_DONE v091=1 subsetCatalog=1 validationError=1 openUrl=1 unsafeUrlBlocked=1 agUiActivity=1 activityReplaceFalse=1 activityReplace=1 activityBucketDelete=1 postDoneControlCreateRejected=1 liveBinding=1 editedContext=1 template=1 legacyHistory=1 presentHistory=1 snapshotAuthority=1 create=1 update=2 delete=3 actions=2 console=0 runtime=0 window=0 network=0\n")
  cleanup()
}
main()
