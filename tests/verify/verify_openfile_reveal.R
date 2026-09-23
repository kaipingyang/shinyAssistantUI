#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
})
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".")
  port <- httpuv::randomPort()
  root <- tempfile("host-callback-fixture-")
  dir.create(file.path(root, "ERP"), recursive = TRUE, mode = "0700")
  root <- normalizePath(root)
  fixture_project <- file.path(root, "ERP")
  live_name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
  history_name <- "\u5386\u53f2_\u4ea4\u63a5.md"
  stopifnot(all(file.create(file.path(fixture_project, c(live_name, history_name)))))
  stdout <- file.path(root, "app.out")
  stderr <- file.path(root, "app.err")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  app <- callr::r_bg(function(project, port, root) {
    setwd(project)
    Sys.setenv(AUI_HOST_FIXTURE_ROOT = root)
    library(shinyAssistantUI)
    installed <- normalizePath(find.package("shinyAssistantUI"))
    stopifnot(startsWith(installed, paste0(normalizePath(path.expand("~")), "/")))
    message("INSTALL=", installed, " VERSION=", packageVersion("shinyAssistantUI"))
    shiny::runApp(
      "tests/verify/openfile_reveal_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  }, args = list(project = project, port = port, root = root), stdout = stdout, stderr = stderr)
  ready <- FALSE
  for (i in seq_len(150L)) {
    if (!app$is_alive()) break
    ready <- any(grepl("Listening on", readLines(stderr, warn = FALSE), fixed = TRUE))
    if (ready) break
    Sys.sleep(0.1)
  }
  if (!ready) stop(paste(readLines(stderr, warn = FALSE), collapse = "\n"), call. = FALSE)
  cat(grep("INSTALL=", readLines(stderr, warn = FALSE), value = TRUE), "\n")

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- ChromoteSession$new(width = 1440, height = 1050)
  errors <- network_errors <- character()
  current_stage <- "mount"
  window_errors <- capture_browser_window_errors(browser, function() current_stage)
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- c(errors, "console.error")
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    network_errors <<- c(network_errors, event$errorText)
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- c(network_errors, event$response$url)
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  quote_js <- function(text) as.character(jsonlite::toJSON(text, auto_unbox = TRUE))
  checks <- 0L
  check <- function(label, ok) {
    current_stage <<- label
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", label))
    checks <<- checks + 1L
    if (!isTRUE(ok)) {
      cat("HOST_PROBE ", value("document.getElementById('host_probe')?.textContent"), "\n")
      cat("DOM ", value("document.body.innerText.slice(-1800)"), "\n")
      cat(c(errors, network_errors, tail(readLines(stderr, warn = FALSE), 15L)), sep = "\n")
      stop("Host callback gate failed: ", label, call. = FALSE)
    }
  }
  wait_for <- function(js, timeout = 10) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(js))) return(TRUE)
      if (!app$is_alive() || Sys.time() > deadline) return(FALSE)
      Sys.sleep(0.05)
    }
  }
  probe <- function(js) paste0(
    "(()=>{const p=JSON.parse(document.getElementById('host_probe').textContent);return ",
    js, "})()"
  )
  click <- function(selector) {
    target <- quote_js(selector)
    check(paste("visible target", selector), wait_for(sprintf(
      "!!document.querySelector(%s)", target
    )))
    value(sprintf("document.querySelector(%s).scrollIntoView({block:'center',behavior:'instant'});true", target))
    Sys.sleep(0.15)
    point <- value(sprintf(
      "(()=>{const e=document.querySelector(%s),r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,visible:r.width>0&&r.height>0&&x>=0&&x<innerWidth&&y>=0&&y<innerHeight&&e.contains(document.elementFromPoint(x,y))}})()",
      target
    ))
    check(paste("pointer target in viewport", selector), point$visible)
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  }
  send <- function(id, text) {
    selector <- paste0("#", id, " .aui-lexical-input[contenteditable=true]")
    click(selector)
    browser$Input$insertText(text = text)
    check(paste(id, "send enabled"), wait_for(sprintf(
      "!!document.querySelector('#%s .aui-composer-send:not([disabled])')", id
    )))
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  }
  history <- function(label) {
    expression <- sprintf(
      "[...document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes(%s))",
      quote_js(paste("Open history", label))
    )
    check(paste("history", label, "available"), wait_for(paste0("!!(", expression, ")")))
    value(paste0("(", expression, ").setAttribute('data-host-history-target','true');true"))
    click("#chat [data-host-history-target=true] button")
    value("document.querySelector('[data-host-history-target]')?.removeAttribute('data-host-history-target');true")
    check(paste("history", label, "restored"), wait_for(sprintf(
      "document.getElementById('chat').innerText.includes('HISTORY_%s_COMPLETE')", label
    )))
  }
  run_button <- function(code) {
    expression <- sprintf(
      "[...document.querySelectorAll('#chat .aui-code-header-root')].find(e=>e.nextElementSibling?.textContent.trim()===%s)?.querySelector('[data-run-in-console]')",
      quote_js(code)
    )
    check(paste("R action for", code), wait_for(paste0("!!(", expression, ")")))
    value(paste0("(", expression, ").setAttribute('data-host-run-target','true');true"))
    click("#chat [data-host-run-target=true]")
    value("document.querySelector('[data-host-run-target]')?.removeAttribute('data-host-run-target');true")
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("three installed widgets mount", wait_for(
    "['chat','other','plain'].every(id=>!!document.querySelector(`#${id} .aui-thread-root`))"
  ))
  check("direct window-error observer is installed", isTRUE(value("window.__auiWindowErrorProbeReady")))
  check("active-file chip has no selection requirement", wait_for(
    "document.querySelector('#chat [data-slot=aui_ide_context]')?.getAttribute('data-context-file')==='R/demo.R'&&!!document.querySelector('#chat [data-slot=aui_selection_visibility]')"
  ))
  click("#chat [data-slot=aui_selection_visibility]")
  check("file context can be hidden", wait_for(
    "document.querySelector('#chat [data-slot=aui_ide_context]')?.getAttribute('data-selection-visible')==='false'"
  ))
  click("#chat [data-slot=aui_selection_visibility]")
  check("file context can be restored", wait_for(
    "document.querySelector('#chat [data-slot=aui_ide_context]')?.getAttribute('data-selection-visible')==='true'"
  ))
  send("chat", "host edit fixture")
  check("live reply fully rendered", wait_for(
    "document.getElementById('chat').innerText.includes('HOST_REPLY_COMPLETE')&&!document.querySelector('#chat .aui-composer-cancel')"
  ))
  check("only last successful edit is automatically revealed once", wait_for(probe(
    "p.chat.opened.length===1&&p.chat.opened[0].path==='R/addin.R'&&p.chat.opened[0].thread===p.chat.messages[0].thread"
  )))
  check("edit list excludes Read and failed Edit", isTRUE(value(probe(
    "p.chat.edits.length===1&&JSON.stringify(p.chat.edits[0].paths)===JSON.stringify(['R/handlers.R','R/addin.R'])"
  ))))
  check("only R and Rscript expose console actions", isTRUE(value(
    "document.querySelectorAll('#chat [data-run-in-console]').length===2&&[...document.querySelectorAll('#chat .aui-code-header-language')].some(e=>e.textContent==='markdown')"
  )))
  click("#chat [data-open-file='R/server.R']")
  check("tool path reaches current-thread callback", wait_for(probe(
    "p.chat.opened.length===2&&p.chat.opened[1].path==='R/server.R'&&p.chat.opened[1].thread===p.chat.messages[0].thread"
  )))
  click("#chat [data-file-ref='addin.R']")
  check("bare name resolves to current-thread tool path", wait_for(probe(
    "p.chat.opened.length===3&&p.chat.opened[2].path==='R/addin.R'"
  )))
  click("#chat [data-file-ref='R/app.R']")
  check("explicit file line is preserved", wait_for(probe(
    "p.chat.opened.length===4&&p.chat.opened[3].path==='R/app.R'&&p.chat.opened[3].line===12"
  )))
  click(paste0("#chat [data-file-ref='ERP/", live_name, "']"))
  check("Unicode project prefix resolves without doubling directory", wait_for(probe(sprintf(
    "p.chat.opened.length===5&&p.chat.opened[4].resolved===%s",
    quote_js(file.path(fixture_project, live_name))
  ))))
  run_button("print(42L)")
  check("successful console feedback is submitted once to the original thread", wait_for(probe(
    "p.chat.console.length===1&&p.chat.console[0].code.trim()==='print(42L)'&&p.chat.messages.length===2&&p.chat.messages[1].text.includes('SYNTHETIC_CHAT_RESULT_42')&&p.chat.messages[1].thread===p.chat.console[0].thread"
  )))
  check("working directory reaches console callback", isTRUE(value(probe(sprintf(
    "p.chat.console[0].project===%s", quote_js(fixture_project)
  )))))
  run_button('stop("SYNTHETIC_HOST_ERROR")')
  check("callback exception becomes explicit error feedback, not success", wait_for(probe(
    "p.chat.console.length===2&&p.chat.messages.length===3&&p.chat.messages[2].text.includes('It errored:')&&p.chat.messages[2].text.includes('Error: SYNTHETIC_HOST_ERROR')&&!p.chat.messages[2].text.includes('Output:')"
  )))

  send("other", "other host fixture")
  check("second widget renders its R action", wait_for(
    "document.getElementById('other').innerText.includes('OTHER_REPLY_COMPLETE')&&document.querySelectorAll('#other [data-run-in-console]').length===1"
  ))
  click("#other [data-run-in-console]")
  check("second widget routes its own result without changing main callback count", wait_for(probe(
    "p.other.console.length===1&&p.other.messages.length===2&&p.other.messages[1].text.includes('SYNTHETIC_OTHER_RESULT_42')&&p.other.messages[1].thread===p.other.console[0].thread&&p.other.console[0].project===null&&p.chat.console.length===2&&p.chat.messages.length===3"
  )))
  send("plain", "no host capability")
  check("widget without console capability has no Run button", wait_for(
    "document.getElementById('plain').innerText.includes('PLAIN_REPLY_COMPLETE')&&document.querySelectorAll('#plain [data-run-in-console]').length===0"
  ))

  for (label in c("A", "B")) {
    history(label)
    check(paste("history", label, "tool remains collapsed"), isTRUE(value(
      "!document.getElementById('chat').innerText.includes('Historical read succeeded')"
    )))
    click("#chat [data-file-ref='dm.R']")
    check(paste("history", label, "bare name and line stay isolated"), wait_for(probe(sprintf(
      "p.chat.opened.at(-1).path==='/synthetic/history-%s/dm.R'&&p.chat.opened.at(-1).line===19&&p.chat.opened.at(-1).thread===p.chat.loads.at(-1).thread",
      tolower(label)
    ))))
    click(paste0("#chat [data-file-ref='ERP/", history_name, "']"))
    check(paste("history", label, "Unicode prefix resolves"), wait_for(probe(sprintf(
      "p.chat.opened.at(-1).resolved===%s", quote_js(file.path(fixture_project, history_name))
    ))))
    run_button(paste0('print("HISTORY_', label, '")'))
    check(paste("history", label, "console feedback retains restored thread"), wait_for(probe(sprintf(
      "p.chat.console.at(-1).code.includes('HISTORY_%s')&&p.chat.console.at(-1).thread===p.chat.loads.at(-1).thread&&p.chat.messages.at(-1).thread===p.chat.loads.at(-1).thread&&p.chat.messages.at(-1).text.includes('SYNTHETIC_CHAT_RESULT_42')",
      label
    ))))
  }
  current_stage <- "multiline-composer-and-viewport-resize"
  value("document.querySelector('#chat .aui-lexical-input').focus();true")
  browser$Input$insertText(text = paste(rep(
    "WINDOW_ERROR_LAYOUT_DRAFT synthetic multiline input", 8L
  ), collapse = "\n"))
  for (size in list(c(640L, 700L), c(480L, 540L), c(1024L, 900L), c(1440L, 1050L))) {
    browser$Emulation$setDeviceMetricsOverride(
      width = size[[1L]], height = size[[2L]], deviceScaleFactor = 1, mobile = FALSE
    )
    browser$Runtime$evaluate(
      "new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))",
      awaitPromise = TRUE, returnByValue = TRUE
    )
    check(paste("draft survives viewport", paste(size, collapse = "x")), isTRUE(value(
      "document.querySelector('#chat .aui-lexical-input')?.textContent.includes('WINDOW_ERROR_LAYOUT_DRAFT')"
    )))
  }
  value("document.querySelector('#chat .aui-lexical-input').focus();true")
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "a", code = "KeyA", windowsVirtualKeyCode = 65L, modifiers = 2L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "a", code = "KeyA", windowsVirtualKeyCode = 65L, modifiers = 2L
  )
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)
  check("layout draft clears without submission", wait_for(
    "document.querySelector('#chat .aui-lexical-input')?.textContent.trim()===''"
  ))
  origin <- value("String(performance.timeOrigin)")
  browser$Page$reload()
  check("full reload creates a new document", wait_for(sprintf(
    "String(performance.timeOrigin)!==%s&&document.readyState==='complete'&&!!document.querySelector('#chat .aui-thread-root')",
    quote_js(origin)
  )))
  history("B")
  check("history restore does not auto-open files or auto-run code", isTRUE(value(probe(
    "p.chat.opened.length===0&&p.chat.console.length===0&&p.chat.edits.length===0&&p.chat.messages.length===0"
  ))))
  click("#chat [data-file-ref='dm.R']")
  check("file routing survives full browser reload", wait_for(probe(
    "p.chat.opened.length===1&&p.chat.opened[0].path==='/synthetic/history-b/dm.R'&&p.chat.opened[0].line===19"
  )))
  run_button('print("HISTORY_B")')
  check("console-result routing survives full browser reload", wait_for(probe(
    "p.chat.console.length===1&&p.chat.messages.length===1&&p.chat.messages[0].text.includes('SYNTHETIC_CHAT_RESULT_42')&&p.chat.messages[0].thread===p.chat.loads[0].thread"
  )))
  check("zero browser console errors and runtime exceptions", length(errors) == 0L)
  check("zero direct window error events across all documents", length(window_errors()) == 0L)
  check("zero network failures", length(network_errors) == 0L)
  cleanup()
  cat("HOST_CALLBACKS_VERIFIED checks=", checks,
      " console=0 runtime=0 window=0 network=0 cleanup=true host=synthetic-callbacks\n", sep = "")
}

main()
