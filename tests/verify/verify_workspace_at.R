suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-at-out-"), tempfile("aui-at-err-"))
  browser <- NULL
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    shiny::runApp("tests/verify/workspace_at_app.R",
                 host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
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
  browser <- ChromoteSession$new(width = 720, height = 760)
  console_errors <- character()
  browser$Runtime$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) {
      console_errors <<- c(console_errors, paste(vapply(event$args, function(arg) {
        as.character(arg$value %||% arg$description %||% "")
      }, character(1)), collapse = " "))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    console_errors <<- c(console_errors, event$exceptionDetails$exception$description %||%
                          event$exceptionDetails$text)
  })
  value <- function(script, await_promise = FALSE) {
    result <- browser$Runtime$evaluate(script, returnByValue = TRUE, awaitPromise = await_promise)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_for <- function(script, timeout = 12) {
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
      cat("Composer/menu state:", value(
        "JSON.stringify((()=>{const e=document.querySelector('.aui-lexical-input[contenteditable=true]'),p=document.querySelector('.aui-mention-popover'),s=getSelection();return {text:e?.textContent,html:e?.innerHTML,active:document.activeElement===e,popover:p?.textContent,anchor:s?.anchorNode?.textContent,offset:s?.anchorOffset}})())"
      ), "\n")
      stop(name, "\n", paste(console_errors, collapse = "\n"))
    }
  }
  press <- function(key, code, keycode, modifiers = 0L) {
    for (type in c("keyDown", "keyUp")) {
      browser$Input$dispatchKeyEvent(type = type, key = key, code = code,
                                    windowsVirtualKeyCode = keycode, modifiers = modifiers)
    }
  }
  clear_composer <- function() {
    value("document.querySelector('.aui-lexical-input[contenteditable=true]').focus(); true")
    press("a", "KeyA", 65L, 2L)
    press("Backspace", "Backspace", 8L)
    check("composer cleared", wait_for(
      "!document.querySelector('.aui-lexical-input[contenteditable=true]').textContent.trim()"
    ))
    # Lexical clears before tap's cursor/trigger effects settle.
    value("new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))",
          await_promise = TRUE)
  }
  highlighted_label <- paste0(
    "document.querySelector('[data-mention-kind][data-highlighted]')",
    "?.querySelector('span')?.textContent.trim()"
  )

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("widget mounted", wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')"))
  value("document.querySelector('.aui-lexical-input[contenteditable=true]').focus(); true")
  browser$Input$insertText(text = "@handlers")
  check("workspace search finds handlers.R", wait_for(
    "[...document.querySelectorAll('[data-mention-kind]')].some(e=>e.textContent.includes('handlers.R'))"
  ))
  check("mention menu is inside the viewport", wait_for(
    "(()=>{const e=document.querySelector('.aui-mention-popover');if(!e)return false;const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()"
  ))

  clear_composer()
  browser$Input$insertText(text = "@R/")
  check("keyboard fixture has multiple mention results", wait_for(
    "document.querySelectorAll('[data-mention-kind]').length>=2 && !!document.querySelector('[data-mention-kind][data-highlighted]')"
  ))
  first <- value(highlighted_label)
  check("first mention has a label", is.character(first) && nzchar(first))
  press("ArrowDown", "ArrowDown", 40L)
  check("ArrowDown moves to the next mention", wait_for(sprintf(
    "!!(%s) && (%s)!==%s", highlighted_label, highlighted_label, toJSON(first, auto_unbox = TRUE)
  )))
  press("ArrowUp", "ArrowUp", 38L)
  check("ArrowUp returns to the previous mention", wait_for(sprintf(
    "(%s)===%s", highlighted_label, toJSON(first, auto_unbox = TRUE)
  )))
  press("Enter", "Enter", 13L)
  check("Enter inserts the highlighted directive", wait_for(sprintf(
    "[...document.querySelectorAll('.aui-lexical-input [data-directive-type]')].some(e=>e.textContent.includes(%s))",
    toJSON(first, auto_unbox = TRUE)
  )))
  check("mention selection closes the menu", wait_for("!document.querySelector('[data-mention-kind]')"))
  Sys.sleep(0.3)
  check("Enter selects without submitting the composer", isTRUE(value(
    "document.querySelectorAll('[data-role=user]').length===0"
  )))

  for (cycle in seq_len(3L)) {
    clear_composer()
    browser$Input$insertText(text = "@handlers")
    check(sprintf("mention menu reopens (cycle %d)", cycle),
          wait_for("!!document.querySelector('[data-mention-kind]')"))
    press("Escape", "Escape", 27L)
    check("Escape closes the mention menu", wait_for("!document.querySelector('[data-mention-kind]')"))
    check("Escape preserves the draft", isTRUE(value(
      "document.querySelector('.aui-lexical-input[contenteditable=true]').textContent.includes('@handlers')"
    )))
  }
  check("no browser console errors or exceptions", length(console_errors) == 0L,
        paste(console_errors, collapse = " | "))
  cleanup()
  cat("WORKSPACE_AT_VERIFY_DONE\n")
}
main()
