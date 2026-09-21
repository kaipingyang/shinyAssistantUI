suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  expected <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
  stopifnot(identical(normalizePath(find.package("shinyAssistantUI")), expected))
  for (file in c("shinyAssistantUI.js", "style.css")) {
    stopifnot(identical(
      unname(tools::md5sum(file.path(project, "inst/www", file))),
      unname(tools::md5sum(file.path(expected, "www", file)))
    ))
  }
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-window-out-"), tempfile("aui-window-err-"))
  browser <- NULL
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    shiny::runApp("tests/verify/virtualized_history_app.R",
                  host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project, port), stdout = logs[[1L]], stderr = logs[[2L]])
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)

  for (i in seq_len(100L)) {
    if (!app$is_alive()) stop(paste(readLines(logs[[2L]], warn = FALSE), collapse = "\n"))
    if (file.exists(logs[[2L]]) &&
        any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
    Sys.sleep(0.1)
  }
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload"
  )))
  browser <- ChromoteSession$new(width = 1000, height = 720)
  errors <- character()
  network_errors <- character()
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) {
      errors <<- c(errors, paste(vapply(event$args, function(arg) {
        as.character(arg$value %||% arg$description %||% "")
      }, character(1)), collapse = " "))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, event$exceptionDetails$exception$description %||%
                    event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors <<- c(network_errors, event$errorText)
  })
  value <- function(script) {
    result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_for <- function(script, timeout = 10) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(script))) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.05)
    }
  }
  check <- function(name, ok, detail = "") {
    cat(sprintf("[%s] %s %s\n", if (isTRUE(ok)) "PASS" else "FAIL", name, detail))
    if (!isTRUE(ok)) {
      if (length(errors)) cat(paste(errors, collapse = "\n"), "\n")
      cat("Geometry:", value("JSON.stringify((()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]');return {top:v?.scrollTop,height:v?.scrollHeight,viewport:v?.clientHeight,active:document.activeElement?.className}})())"), "\n")
      stop(name)
    }
  }
  open_history <- function(title) {
    value(sprintf(
      "(()=>{const row=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes(%s));const button=row?.querySelector('[data-slot=aui_thread-list-item-trigger]')||row;button?.click();return !!button})()",
      toJSON(title, auto_unbox = TRUE)
    ))
  }
  browser$Page$navigate(sprintf("http://127.0.0.1:%d", port))
  browser$Page$loadEventFired()
  check("fixture sessions arrive", wait_for("document.body.innerText.includes('Virtual History')"))
  check("history opens through the real sidebar", open_history("Virtual History"))
  check("latest history loads", wait_for(
    "document.querySelector('[data-message-id=\"history-360\"]') && document.querySelector('[data-slot=aui_virtualized-messages]')?.dataset.messageCount==='90'"
  ))
  value("window.vp=document.querySelector('[data-slot=aui_thread-viewport]'); window.rows=()=>[...document.querySelectorAll('[data-slot=aui_message-slot]')]; true")
  check("requested height bounds the viewport", isTRUE(value(
    "document.getElementById('chat').style.height==='100vh' && vp.clientHeight<=innerHeight+1 && vp.clientHeight>300"
  )))
  check("90 messages do not create 90 row placeholders", isTRUE(value("rows().length<=48 && rows().length>0")))
  check("initial history follows to bottom", wait_for("vp.scrollHeight-vp.clientHeight-vp.scrollTop<3"))

  value("window.churn=0;window.mountObserver=new MutationObserver(xs=>{for(const x of xs)for(const n of [...x.addedNodes,...x.removedNodes])if(n.nodeType===1&&n.matches?.('[data-slot=aui_message-slot]'))churn++});mountObserver.observe(document.querySelector('[data-slot=aui_virtualized-messages]'),{childList:true});window.idleTop=vp.scrollTop;true")
  Sys.sleep(1)
  check("idle window does not oscillate", isTRUE(value("churn===0 && Math.abs(vp.scrollTop-idleTop)<1")))

  value("vp.style.scrollBehavior='auto';vp.scrollTop=vp.scrollHeight/2;true")
  Sys.sleep(0.5)
  value("window.anchorRow=rows().find(e=>{const r=e.getBoundingClientRect(),v=vp.getBoundingClientRect();return r.bottom>v.top+45&&r.top<v.bottom-100});window.anchorId=anchorRow.dataset.messageId;window.anchorY=anchorRow.getBoundingClientRect().top;window.beforeCount=Number(document.querySelector('[data-slot=aui_virtualized-messages]').dataset.messageCount);document.querySelector('[data-slot=aui_load_older]').click();true")
  check("older page prepends", wait_for("Number(document.querySelector('[data-slot=aui_virtualized-messages]').dataset.messageCount)>beforeCount"))
  Sys.sleep(0.5)
  drift <- value("Math.abs(document.querySelector(`[data-message-id='${anchorId}']`).getBoundingClientRect().top-anchorY)")
  check("prepend preserves the visible message anchor", drift <= 2, sprintf("drift=%.2fpx", drift))
  check("prepend keeps the reading subtree mounted", isTRUE(value(
    "anchorRow.isConnected && document.querySelector(`[data-message-id='${anchorId}']`)===anchorRow"
  )))

  value("vp.scrollTop=0;true")
  check("scrolling up mounts old messages", wait_for(
    "rows().some(e=>Number(e.dataset.messageIndex)<10)"
  ))
  Sys.sleep(0.6)
  check("scrollspy uses global history order", isTRUE(value(
    "(()=>{const crossed=rows().filter(e=>e.querySelector('[data-role=user]')&&e.getBoundingClientRect().top<=vp.getBoundingClientRect().top+40);const row=crossed.at(-1);if(!row)return false;const text=row.querySelector('.aui-user-message-content')?.innerText;return !!text&&document.querySelector('[data-slot=aui_current_question]')?.innerText.includes(text)})()"
  )))
  value("vp.scrollTop=vp.scrollHeight*.35;true")
  Sys.sleep(0.5)
  check("middle window still has bounded mounts", isTRUE(value("rows().length<=48")))

  edit_point <- value("(()=>{const n=Number(document.querySelector('[data-slot=aui_virtualized-messages]').dataset.messageCount),v=vp.getBoundingClientRect();const row=rows().find(e=>{const r=e.getBoundingClientRect();return e.querySelector('[data-role=user]')&&Number(e.dataset.messageIndex)<n-8&&r.top>=v.top+60&&r.bottom<v.bottom-180});if(!row)return null;window.editId=row.dataset.messageId;const r=row.querySelector('.aui-user-message-content').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()")
  check("historical user bubble is in the viewport", !is.null(edit_point))
  browser$Input$dispatchMouseEvent(type = "mouseMoved", x = edit_point$x, y = edit_point$y)
  check("hover reveals the historical edit control", wait_for(
    "!!document.querySelector(`[data-message-id='${editId}'] .aui-user-action-edit`)"
  ))
  value("document.querySelector(`[data-message-id='${editId}'] .aui-user-action-edit`).click();true")
  check("historical user message enters edit mode", wait_for("!!document.querySelector('.aui-edit-composer-input')"))
  value("document.querySelector('.aui-edit-composer-input').focus();true")
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "a", code = "KeyA", modifiers = 2L, windowsVirtualKeyCode = 65L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "a", code = "KeyA", modifiers = 2L, windowsVirtualKeyCode = 65L)
  browser$Input$insertText(text = "PRESERVED_UNSENT_EDIT")
  value("window.editElement=document.querySelector('.aui-edit-composer-input');editElement.blur();vp.scrollTop=vp.scrollHeight;true")
  Sys.sleep(0.5)
  check("offscreen editor keeps its DOM and unsent draft", isTRUE(value(
    "document.querySelector('.aui-edit-composer-input')===editElement && editElement.value==='PRESERVED_UNSENT_EDIT' && rows().length<=49"
  )))
  value("[...document.querySelectorAll('.aui-edit-composer-footer button')].find(e=>e.textContent==='Cancel').click();true")
  check("edit cancellation unpins the historical row", wait_for(
    "!document.querySelector('.aui-edit-composer-input') && !document.querySelector(`[data-message-id='${editId}']`)"
  ))

  value("vp.scrollTop=vp.scrollHeight*.45;true")
  Sys.sleep(0.4)
  value("window.resizeAnchor=rows().find(e=>e.getBoundingClientRect().bottom>vp.getBoundingClientRect().top);window.resizeId=resizeAnchor.dataset.messageId;window.resizeY=resizeAnchor.getBoundingClientRect().top-vp.getBoundingClientRect().top;true")
  browser$Emulation$setDeviceMetricsOverride(width = 640L, height = 600L, deviceScaleFactor = 1, mobile = FALSE)
  Sys.sleep(0.7)
  check("resizing retains a bounded live window", isTRUE(value(
    "vp.clientHeight<=601 && rows().length<=48 && rows().every(e=>e.getBoundingClientRect().height>=0)"
  )))
  resize_drift <- value("Math.abs(document.querySelector(`[data-message-id='${resizeId}']`).getBoundingClientRect().top-vp.getBoundingClientRect().top-resizeY)")
  check("resizing preserves the reading anchor", resize_drift <= 2, sprintf("drift=%.2fpx", resize_drift))
  check("resizing keeps the reading subtree mounted", isTRUE(value(
    "resizeAnchor.isConnected && document.querySelector(`[data-message-id='${resizeId}']`)===resizeAnchor"
  )))
  check("another session opens", open_history("Other History"))
  check("thread switch discards old window geometry", wait_for(
    "document.querySelector('[data-message-id=\"other-012\"]') && !document.querySelector('[data-message-id^=\"history-\"]')"
  ))
  check("small thread remains completely mounted", isTRUE(value("rows().length===12")))
  check("original history can be restored", open_history("Virtual History"))
  check("restored history is usable", wait_for("!!document.querySelector('[data-message-id=\"history-360\"]')"))
  value("vp.scrollTop=vp.scrollHeight*.4;true")
  Sys.sleep(0.4)
  value("document.querySelector('.aui-lexical-input[contenteditable=true]').focus();true")
  browser$Input$insertText(text = "STREAM_FROM_OLD_HISTORY")
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  check("real composer starts the stream", wait_for("document.body.innerText.includes('STREAM_005')"))
  check("new submission follows from history to latest", wait_for("vp.scrollHeight-vp.clientHeight-vp.scrollTop<4"))
  point <- value("(()=>{const r=vp.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+150}})()")
  browser$Input$dispatchMouseEvent(type = "mouseWheel", x = point$x, y = point$y, deltaX = 0, deltaY = -900)
  Sys.sleep(0.4)
  value("window.detachedTop=vp.scrollTop;true")
  Sys.sleep(0.6)
  check("upward wheel detaches while the stream grows", isTRUE(value(
    "Math.abs(vp.scrollTop-detachedTop)<3 && vp.scrollHeight-vp.clientHeight-vp.scrollTop>100"
  )))
  value("document.querySelector('.aui-thread-scroll-to-bottom').click();true")
  check("existing bottom button resumes follow", wait_for("vp.scrollHeight-vp.clientHeight-vp.scrollTop<4"))
  check("stream finishes without losing its tail", wait_for(
    "document.getElementById('stream_finished')?.textContent==='TRUE' && document.body.innerText.includes('STREAM_080')", 15
  ))
  check("stream remains bottom aligned", wait_for("vp.scrollHeight-vp.clientHeight-vp.scrollTop<4"))
  check("console/runtime errors", length(errors) == 0L, paste(errors, collapse = " | "))
  check("network failures", length(network_errors) == 0L, paste(network_errors, collapse = " | "))
  cat(sprintf("VIRTUALIZED_HISTORY_PASS mounted=%s errors=%d network=%d\n",
              value("rows().length"), length(errors), length(network_errors)))
  cleanup()
}
main()
