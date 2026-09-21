#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(chromote)
  library(callr)
  library(jsonlite)
})

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
  stopifnot(
    identical(normalizePath(find.package("shinyAssistantUI")), home),
    as.character(packageVersion("shinyAssistantUI")) == read.dcf("DESCRIPTION", "Version")[[1L]]
  )
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-media-out-"), tempfile("aui-media-err-"))
  browser <- NULL
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    shiny::runApp("tests/verify/verify_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  }, args = list(project, port), stdout = logs[[1L]], stderr = logs[[2L]])
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  for (i in seq_len(100L)) {
    if (!app$is_alive()) stop(paste(readLines(logs[[2L]], warn = FALSE), collapse = "\n"))
    if (file.exists(logs[[2L]]) &&
      any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) {
      break
    }
    Sys.sleep(0.1)
  }
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload"
  )))
  browser <- ChromoteSession$new(width = 1200, height = 800)
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
  wait_for <- function(script, timeout = 12) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(script))) {
        return(TRUE)
      }
      if (Sys.time() >= deadline) {
        return(FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  check <- function(name, ok) {
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", name))
    if (!isTRUE(ok)) {
      cat("DOM_STATE ", value("document.body.innerText.slice(0,1800)"), "\n")
      stop(name, "\n", paste(c(errors, network_errors), collapse = "\n"))
    }
  }
  key <- function(name, code, vk) {
    for (type in c("keyDown", "keyUp")) {
      browser$Input$dispatchKeyEvent(
        type = type, key = name, code = code, windowsVirtualKeyCode = as.integer(vk)
      )
    }
  }
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("installed composer mounted", wait_for(
    "!!document.querySelector('.aui-lexical-input[contenteditable=true]')"
  ))
  value(paste0(
    "window.streamSnapshots=[];window.streamObserver=new MutationObserver(()=>{",
    "const text=[...document.querySelectorAll('[data-slot=aui_assistant-text]')]",
    ".map(e=>e.textContent).join('');if(text&&!streamSnapshots.includes(text))streamSnapshots.push(text)});",
    "streamObserver.observe(document.querySelector('.aui-root'),{subtree:true,childList:true,characterData:true});",
    "document.querySelector('.aui-lexical-input[contenteditable=true]').focus();true"
  ))
  browser$Input$insertText(text = "run research")
  key("Enter", "Enter", 13L)
  check("final streamed answer arrives", wait_for(
    "document.body.innerText.includes('final streamed answer for verification purposes')"
  ))
  check("multiple partial replies rendered before completion", isTRUE(value(
    "streamSnapshots.length>=3&&streamSnapshots.some(t=>!t.includes('verification purposes'))"
  )))
  check("user message is preserved", isTRUE(value(
    "document.querySelector('[data-role=user]')?.textContent.includes('run research')"
  )))
  check("reasoning card is present", wait_for(
    "!!document.querySelector('[data-slot=reasoning-trigger]')"
  ))
  value("document.querySelectorAll('[data-slot=reasoning-trigger][aria-expanded=false]').forEach(e=>e.click());true")
  check("reasoning disclosure preserves its actual content", wait_for(
    "document.querySelector('[data-slot=reasoning-content]')?.textContent.includes('Analyzing the request and planning sub-agent delegation.')"
  ))
  check("four tool cards are present exactly once", wait_for(
    "document.querySelectorAll('[data-tool-depth]').length===4"
  ))
  check("parent, child and grandchild depths are exact", isTRUE(value(
    "JSON.stringify([...document.querySelectorAll('[data-tool-depth]')].map(e=>Number(e.dataset.toolDepth)))===JSON.stringify([0,1,1,2])"
  )))
  check("nested cards have increasing visual indentation", isTRUE(value(
    "(()=>{const rows=[...document.querySelectorAll('[data-tool-depth]')];return parseFloat(getComputedStyle(rows[1]).marginInlineStart)>0&&parseFloat(getComputedStyle(rows[3]).marginInlineStart)>parseFloat(getComputedStyle(rows[1]).marginInlineStart)})()"
  )))
  value("document.querySelectorAll('[data-slot=tool-fallback-trigger][aria-expanded=false]').forEach(e=>e.click());true")
  check("synthetic tool results are readable", wait_for(
    "document.body.innerText.includes('Research complete')&&document.body.innerText.includes('Found 12 results')&&document.body.innerText.includes('Summary complete')"
  ))
  check("follow-up suggestions remain available", wait_for(
    "document.body.innerText.includes('Tell me more about climate data')&&document.body.innerText.includes('What are the sources?')"
  ))
  source_check <- paste0(
    "document.querySelectorAll('.aui-source-cite').length===2&&",
    "[...document.querySelectorAll('.aui-source-cite a')].some(e=>",
    "e.textContent==='Reference Paper'&&e.href==='https://example.com/paper'&&e.target==='_blank')&&",
    "[...document.querySelectorAll('.aui-source-cite a')].some(e=>e.textContent==='Wikipedia: AI')"
  )
  image_check <- "(()=>{const e=document.querySelector('img.aui-message-image');return !!e&&e.src.startsWith('data:image/png;base64,')&&e.complete&&e.naturalWidth===1})()"
  check("source titles and safe citation links render", wait_for(source_check))
  check("native PNG image decodes successfully", wait_for(image_check))
  check("Markdown artifact has title, heading and list", wait_for(
    "document.querySelector('.aui-artifact-title')?.textContent==='Project Plan'&&document.querySelector('.aui-artifact-markdown h1')?.textContent==='Project Plan'&&document.querySelectorAll('.aui-artifact-markdown li').length===2"
  ))
  check("artifact panel stays inside viewport", isTRUE(value(
    "(()=>{const r=document.querySelector('.aui-artifact-panel').getBoundingClientRect();return r.width>0&&r.height>0&&r.top>=0&&r.left>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()"
  )))
  close_point <- value(
    "(()=>{const e=document.querySelector('.aui-artifact-close'),r=e.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()"
  )
  check("artifact close button receives the pointer", isTRUE(value(sprintf(
    "document.querySelector('.aui-artifact-close').contains(document.elementFromPoint(%f,%f))",
    close_point$x, close_point$y
  ))))
  for (type in c("mousePressed", "mouseReleased")) {
    browser$Input$dispatchMouseEvent(
      type = type, x = close_point$x, y = close_point$y, button = "left", clickCount = 1L
    )
  }
  check("artifact panel closes through its real button", wait_for(
    "!document.querySelector('.aui-artifact-panel')"
  ))
  check("assistant action bar and thread sidebar survive", isTRUE(value(
    "!!document.querySelector('[data-slot=aui_assistant-message-footer]')&&!!document.querySelector('[data-slot=aui_thread_sidebar]')"
  )))
  value("streamObserver.disconnect();true")
  browser$Page$reload()
  browser$Page$loadEventFired()
  check("history restores final answer and exact tool count", wait_for(
    "document.body.innerText.includes('final streamed answer for verification purposes')&&document.querySelectorAll('[data-tool-depth]').length===4"
  ))
  check("history retains nested tool depths", isTRUE(value(
    "JSON.stringify([...document.querySelectorAll('[data-tool-depth]')].map(e=>Number(e.dataset.toolDepth)))===JSON.stringify([0,1,1,2])"
  )))
  check("history restores sources and native image", wait_for(paste0(
    "(", source_check, ")&&(", image_check, ")"
  )))
  check("zero console/runtime errors", length(errors) == 0L)
  check("zero network loading failures", length(network_errors) == 0L)
  cleanup()
  cat("MESSAGE_MEDIA_CHROMIUM_DONE\n")
}
main()
