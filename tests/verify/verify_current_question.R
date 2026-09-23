suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})
main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  source("tests/verify/window_error_capture.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  proj <- normalizePath(".", winslash = "/", mustWork = TRUE)
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-question-out-"), tempfile("aui-question-err-"))
  failures <- character()
  chk <- function(name, cond, detail = "") {
    ok <- isTRUE(cond)
    cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
    if (!ok) failures <<- c(failures, name)
    invisible(ok)
  }
  app <- callr::r_bg(function(proj, port) {
    setwd(proj)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp("tests/verify/current_question_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(proj = proj, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
  b <- NULL
  cleanup <- make_verification_cleanup(function() b, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  for (i in 1:120) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2L]]) && any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
    Sys.sleep(0.25)
  }
  if (!app$is_alive()) {
    cat(tail(readLines(logs[[2L]], warn = FALSE), 15), sep = "\n")
    stop("boot failed")
  }

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  b <- ChromoteSession$new(width = 620, height = 480)
  errs <- character()
  window_errors <- capture_browser_window_errors(b, function() "current-question")
  b$Runtime$consoleAPICalled(callback_ = function(m) {
    if (identical(m$type, "error")) {
      errs <<- c(errs, paste(vapply(m$args, function(a) as.character(a$value %||% a$description %||% ""), character(1)), collapse = " "))
    }
  })
  b$Runtime$exceptionThrown(callback_ = function(m) {
    errs <<- c(
      errs, m$exceptionDetails$exception$description %||% m$exceptionDetails$text
    )
  })
  val <- function(s) {
    r <- b$Runtime$evaluate(s, returnByValue = TRUE)
    if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text)
    r$result$value
  }
  wait <- function(s, t = 15) {
    d <- Sys.time() + t
    repeat {
      if (isTRUE(tryCatch(val(s), error = function(e) FALSE))) {
        return(TRUE)
      }
      if (Sys.time() >= d) {
        return(FALSE)
      }
      Sys.sleep(0.1)
    }
  }
  click_sel <- function(sel) {
    j <- val(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", toJSON(sel, auto_unbox = TRUE)))
    if (is.null(j)) {
      return(FALSE)
    }
    p <- fromJSON(j)
    b$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
    b$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
    TRUE
  }
  send <- function(text, n) {
    click_sel(".aui-lexical-input[contenteditable='true']")
    Sys.sleep(0.3)
    b$Input$insertText(text = text)
    Sys.sleep(0.2)
    b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    b$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    chk(paste("completed reply", n), wait(sprintf(
      "document.querySelectorAll('[data-role=assistant]').length===%d && !document.querySelector('.aui-composer-cancel')",
      n
    ), 15))
  }
  barText <- function() val("(document.querySelector('[data-slot=aui_current_question]')||{}).textContent||''")
  setScroll <- function(topExpr) {
    val(sprintf("(function(){var v=document.querySelector('[data-slot=aui_thread-viewport]');v.style.scrollBehavior='auto';v.scrollTop=%s;return true})()", topExpr))
    chk("viewport reaches requested scroll position", wait(sprintf(
      "(()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]');return Math.abs(v.scrollTop-Math.min(%s,v.scrollHeight-v.clientHeight))<=1})()",
      topExpr
    ), 5))
    Sys.sleep(0.2)
    cat("SCROLL_GEOMETRY ", val(
      "JSON.stringify((()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]'),l=document.querySelector('[data-slot=aui_virtualized-messages]');return {scrollTop:v.scrollTop,scrollHeight:v.scrollHeight,viewportHeight:v.clientHeight,listTop:l.getBoundingClientRect().top-v.getBoundingClientRect().top,question:document.querySelector('[data-slot=aui_current_question]')?.textContent}})())"
    ), "\n")
  }

  b$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  b$Page$loadEventFired()
  chk("widget mounted", wait("!!document.querySelector('.aui-root')", 12))
  chk("direct window-error observer is installed", isTRUE(val("window.__auiWindowErrorProbeReady")))
  send("QUESTION ONE alpha", 1)
  send("QUESTION TWO beta", 2)
  send("QUESTION THREE gamma", 3)
  chk("three user turns present", isTRUE(val("document.querySelectorAll('[data-role=\"user\"]').length>=3")))
  chk("pinned bar exists (content overflows)", wait("!!document.querySelector('[data-slot=aui_current_question]')", 8))

  setScroll("0") # 滚到顶
  chk("scrolled to top -> bar shows Q1 (ONE), not Q3", wait(
    "document.querySelector('[data-slot=aui_current_question]')?.textContent.includes('ONE')", 3
  ), barText())

  setScroll("v.scrollHeight") # 滚到底
  chk("scrolled to bottom -> bar shows Q3 (THREE)", isTRUE(grepl("THREE", barText())), barText())

  b$Page$reload()
  b$Page$loadEventFired()
  chk("three turns restore from history", wait(
    "document.querySelectorAll('[data-role=user]').length===3 && document.querySelectorAll('[data-role=assistant]').length===3", 12
  ))
  setScroll("0")
  chk("restored history at top also shows Q1", wait(
    "document.querySelector('[data-slot=aui_current_question]')?.textContent.includes('ONE')", 3
  ), barText())

  chk("no browser console errors", length(errs) == 0, if (length(errs)) paste(utils::head(errs, 3), collapse = " | ") else "0 errors")
  chk("no direct window error events", length(window_errors()) == 0L)
  cleanup()
  if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
  cat("CURRENT_QUESTION_VERIFY_DONE\n")
}
main()
