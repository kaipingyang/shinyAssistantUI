suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/")
  home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  expected_version <- read.dcf("DESCRIPTION", fields = "Version")[[1L]]
  stopifnot(as.character(packageVersion("shinyAssistantUI", lib.loc = home_library)) == expected_version)
  for (file in c("shinyAssistantUI.js", "style.css")) {
    stopifnot(identical(
      unname(tools::md5sum(file.path(project, "inst/www", file))),
      unname(tools::md5sum(file.path(home_library, "shinyAssistantUI/www", file)))
    ))
  }
  port <- httpuv::randomPort()
  log_out <- tempfile("p1-correctness-", fileext = ".out")
  log_err <- tempfile("p1-correctness-", fileext = ".err")
  failures <- character()

  check <- function(name, condition, detail = "") {
    passed <- isTRUE(condition)
    cat(sprintf("[%s] %-62s %s\n", if (passed) "PASS" else "FAIL", name, detail))
    if (!passed) failures <<- c(failures, name)
    invisible(passed)
  }

  app <- callr::r_bg(
    function(project, port, home_library) {
      setwd(project)
      Sys.setenv(AUI_HOME_LIB = home_library)
      suppressPackageStartupMessages(library(shiny))
      fixture <- source("tests/verify/p1_correctness_app.R", local = new.env())$value
      shiny::runApp(
        fixture,
        host = "127.0.0.1",
        port = port,
        launch.browser = FALSE
      )
    },
    args = list(project = project, port = port, home_library = home_library),
    stdout = log_out,
    stderr = log_err
  )
  browser <- NULL
  cleanup <- make_verification_cleanup(
    browser_session = function() browser,
    app_process = function() app,
    paths = c(log_out, log_err)
  )
  on.exit(cleanup(), add = TRUE)

  booted <- FALSE
  for (i in seq_len(80L)) {
    if (!app$is_alive()) break
    lines <- if (file.exists(log_err)) readLines(log_err, warn = FALSE) else character()
    if (any(grepl("Listening on", lines, fixed = TRUE))) {
      booted <- TRUE
      break
    }
    Sys.sleep(0.25)
  }
  if (!booted) {
    cat(tail(readLines(log_err, warn = FALSE), 30L), sep = "\n")
    stop("P1 fixture failed to boot")
  }

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(),
    "--disable-dev-shm-usage",
    "--no-sandbox",
    "--disable-gpu"
  )))
  browser <- ChromoteSession$new(width = 900, height = 900)

  console_errors <- character()
  runtime_exceptions <- character()
  network_failures <- character()
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(message) {
    if (identical(message$type, "error")) {
      values <- vapply(message$args, function(arg) as.character(arg$value %||% ""), character(1L))
      console_errors <<- c(console_errors, paste(values, collapse = " "))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(message) {
    runtime_exceptions <<- c(
      runtime_exceptions,
      as.character(message$exceptionDetails$text %||% "unknown exception")
    )
  })
  browser$Network$loadingFailed(callback_ = function(message) {
    network_failures <<- c(
      network_failures,
      paste(message$errorText %||% "unknown", message$type %||% "", sep = ":")
    )
  })

  value <- function(script) {
    result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_for <- function(script, timeout = 12, interval = 0.05) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(script), error = function(e) FALSE))) {
        return(TRUE)
      }
      if (Sys.time() >= deadline) {
        return(FALSE)
      }
      Sys.sleep(interval)
    }
  }
  point_for <- function(selector, index = "last") {
    encoded <- jsonlite::toJSON(selector, auto_unbox = TRUE)
    script <- sprintf(
      paste0(
        "(function(){const a=Array.from(document.querySelectorAll(%s));",
        "if(!a.length)return null;const e=%s==='first'?a[0]:a[a.length-1];",
        "e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();",
        "return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2,",
        "visible:r.width>0&&r.height>0&&r.bottom>0&&r.right>0&&",
        "r.top<innerHeight&&r.left<innerWidth});})()"
      ),
      encoded,
      jsonlite::toJSON(index, auto_unbox = TRUE)
    )
    raw <- value(script)
    if (is.null(raw)) {
      return(NULL)
    }
    jsonlite::fromJSON(raw)
  }
  click_element <- function(selector, index = "last") {
    point <- point_for(selector, index)
    if (is.null(point) || !isTRUE(point$visible)) {
      return(FALSE)
    }
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
  press_enter <- function() {
    browser$Input$dispatchKeyEvent(
      type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
    )
    browser$Input$dispatchKeyEvent(
      type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
    )
  }
  send_message <- function(root, text) {
    selector <- paste0(root, " .aui-lexical-input[contenteditable='true']")
    if (!click_element(selector)) {
      return(FALSE)
    }
    Sys.sleep(0.15)
    browser$Input$insertText(text = text)
    Sys.sleep(0.15)
    press_enter()
    TRUE
  }
  last_reply <- function(root) {
    value(sprintf(
      "(function(){const a=document.querySelectorAll('%s [data-role=assistant]');return a.length?a[a.length-1].innerText:''})()",
      root
    )) %||% ""
  }
  extract_attachment_fingerprint <- function(text) {
    match <- regexec("ATT_NAME=([^ ]+) ATT_LEN=([0-9]+) ATT_SUM=([0-9]+)", text)
    values <- regmatches(text, match)[[1L]]
    if (length(values) != 4L) {
      return(NULL)
    }
    unname(values[2:4])
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("both widgets mounted", wait_for(
    "document.querySelectorAll('.aui-root').length===2", 15
  ))
  check("fixture uses exact HOME-installed package", isTRUE(value(sprintf(
    "document.querySelector('#package-meta').dataset.packagePath===%s && document.querySelector('#package-meta').dataset.packageVersion===%s",
    jsonlite::toJSON(file.path(home_library, "shinyAssistantUI"), auto_unbox = TRUE),
    jsonlite::toJSON(expected_version, auto_unbox = TRUE)
  ))))

  check("seed message submitted through enabled composer", send_message("#chat_on", "seed marker"))
  check("seed assistant reply completed", wait_for(
    "Array.from(document.querySelectorAll('#chat_on [data-role=assistant]')).some(e=>(e.innerText||'').includes('ON_RUN=1 RELOAD=FALSE')&&(e.innerText||'').includes('prices $5 through $10'))",
    15
  ))
  check("custom LaTeX delimiters both render via KaTeX", wait_for(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');const e=a[a.length-1];return !!(e&&e.querySelectorAll('.katex').length>=2)})()",
    5
  ), paste0("katex=", value(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');const e=a[a.length-1];return e?e.querySelectorAll('.katex').length:0})()"
  )))
  check("currency dollars remain literal text in seed reply", grepl("$5", last_reply("#chat_on"), fixed = TRUE) &&
    grepl("$10", last_reply("#chat_on"), fixed = TRUE))

  selected <- value(paste0(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');",
    "if(!a.length)return '';const e=a[a.length-1];const r=document.createRange();",
    "r.selectNodeContents(e);const s=getSelection();s.removeAllRanges();s.addRange(r);",
    "document.dispatchEvent(new Event('selectionchange'));",
    "e.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));",
    "document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));",
    "document.dispatchEvent(new Event('selectionchange'));return s.toString();})()"
  ))
  check("assistant response text selected for quote", grepl("ON_RUN=1", selected, fixed = TRUE))
  check("quote toolbar appears", wait_for(
    "!!document.querySelector('.aui-selection-toolbar-quote')", 5
  ))
  check("quote toolbar is fully inside the viewport", wait_for(
    "(()=>{const e=document.querySelector('.aui-selection-toolbar');if(!e)return false;const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()",
    5
  ))
  check("quote action clicked in viewport", click_element(".aui-selection-toolbar-quote"))
  check("composer quote preview preserves seed response", wait_for(
    "(document.querySelector('.aui-composer-quote')?.innerText||'').includes('ON_RUN=1')",
    5
  ))

  file_content <- "P1-ATTACHMENT-ORIGINAL"
  attached <- value(sprintf(
    paste0(
      "(function(){const f=new File([%s],'p1-original.txt',{type:'text/plain'});",
      "const dt=new DataTransfer();dt.items.add(f);",
      "const e=document.querySelector('#chat_on .aui-lexical-input[contenteditable=true]');",
      "['dragenter','dragover','drop'].forEach(t=>e.dispatchEvent(new DragEvent(t,",
      "{dataTransfer:dt,bubbles:true,cancelable:true})));return true;})()"
    ),
    jsonlite::toJSON(file_content, auto_unbox = TRUE)
  ))
  check("original text attachment dropped into composer", isTRUE(attached) && wait_for(
    "document.querySelectorAll('#chat_on .aui-composer-attachments .aui-attachment-root').length===1",
    5
  ))
  check("quoted attachment turn submitted", send_message("#chat_on", "quoted attachment turn"))
  check("initial quoted attachment run completed", wait_for(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');return a.length&&(a[a.length-1].innerText||'').includes('ON_RUN=2 RELOAD=FALSE')&&(a[a.length-1].innerText||'').includes('prices $5 through $10')})()",
    15
  ))
  check("R received original quote on first send", wait_for(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');const t=a.length?(a[a.length-1].innerText||''):'';return t.includes('ON_RUN=1')&&t.includes('quoted attachment turn')})()",
    5
  ))
  reply_before_reload <- last_reply("#chat_on")
  fingerprint_before <- extract_attachment_fingerprint(reply_before_reload)
  check(
    "R received live attachment bytes on first send",
    !is.null(fingerprint_before) && identical(fingerprint_before[[1L]], "p1-original.txt") &&
      as.integer(fingerprint_before[[2L]]) > 0L,
    paste(fingerprint_before %||% "missing", collapse = "/")
  )

  check("Refresh action exists for latest assistant response", wait_for(
    "document.querySelectorAll('#chat_on button:has(svg.lucide-refresh-cw)').length>=1", 5
  ))
  check("Refresh clicked in viewport", click_element("#chat_on button:has(svg.lucide-refresh-cw)"))
  reload_condition <- paste0(
    "(function(){const a=document.querySelectorAll('#chat_on [data-role=assistant]');",
    "return a.length&&(a[a.length-1].innerText||'').includes('ON_RUN=3 RELOAD=TRUE')&&",
    "(a[a.length-1].innerText||'').includes('prices $5 through $10')})()"
  )
  reload_completed <- wait_for(reload_condition, 20)
  check("reload run completed", reload_completed)
  reply_after_reload <- last_reply("#chat_on")
  fingerprint_after <- extract_attachment_fingerprint(reply_after_reload)
  check("reload replays original quote", grepl("ON_RUN=3 RELOAD=TRUE", reply_after_reload, fixed = TRUE) &&
    grepl("ON_RUN=1", reply_after_reload, fixed = TRUE) &&
    grepl("quoted attachment turn", reply_after_reload, fixed = TRUE))
  check(
    "reload replays identical attachment fingerprint",
    !is.null(fingerprint_before) && identical(fingerprint_after, fingerprint_before),
    paste(fingerprint_after %||% "missing", collapse = "/")
  )

  check("currency dollars remain literal after reload", grepl("$5", reply_after_reload, fixed = TRUE) &&
    grepl("$10", reply_after_reload, fixed = TRUE))

  check("enabled capability exposes positive feedback", wait_for(
    "document.querySelectorAll('#chat_on button.aui-feedback-positive').length>=1", 5
  ))
  check(
    "positive feedback clicked in viewport",
    click_element("#chat_on button.aui-feedback-positive", "first")
  )
  check("positive feedback reaches R callback", wait_for(
    "(document.querySelector('#feedback_log')?.innerText||'').includes('positive')", 5
  ))
  check(
    "negative feedback clicked in viewport",
    click_element("#chat_on button.aui-feedback-negative", "last")
  )
  check("negative feedback reaches R callback", wait_for(
    "(document.querySelector('#feedback_log')?.innerText||'').includes('positive|negative')", 5
  ))

  for (method in c("paste", "drop")) {
    before <- value("document.querySelectorAll('#chat_off .aui-composer-attachments .aui-attachment-root').length")
    check(paste(method, "image is dispatched to the real composer"), isTRUE(value(sprintf(
      paste0(
        "(()=>{const c=document.createElement('canvas');c.width=c.height=1;",
        "c.getContext('2d').fillRect(0,0,1,1);",
        "const bytes=Uint8Array.from(atob(c.toDataURL('image/png').split(',')[1]),c=>c.charCodeAt(0));",
        "const f=new File([bytes],%s,{type:'image/png'}),dt=new DataTransfer();dt.items.add(f);",
        "const e=document.querySelector('#chat_off .aui-lexical-input[contenteditable=true]');",
        "e.focus();if(%s==='paste'){e.dispatchEvent(new ClipboardEvent('paste',",
        "{clipboardData:dt,bubbles:true,cancelable:true}));}else{",
        "['dragenter','dragover','drop'].forEach(t=>e.dispatchEvent(new DragEvent(t,",
        "{dataTransfer:dt,bubbles:true,cancelable:true})));}return true})()"
      ),
      toJSON(paste0(method, ".png"), auto_unbox = TRUE),
      toJSON(method, auto_unbox = TRUE)
    ))))
    check(paste(method, "adds exactly one image attachment"), wait_for(sprintf(
      "document.querySelectorAll('#chat_off .aui-composer-attachments .aui-attachment-root').length===%d",
      before + 1L
    ), 5))
  }
  check("disabled widget message submitted", send_message("#chat_off", "disabled feedback"))
  check("disabled widget assistant reply completed", wait_for(
    "(function(){const a=document.querySelectorAll('#chat_off [data-role=assistant]');return a.length&&(a[a.length-1].innerText||'').includes('OFF_RUN=1')})()",
    15
  ))
  check("feedback buttons absent when on_feedback is NULL", isTRUE(value(
    "document.querySelectorAll('#chat_off button[aria-label=\"Good response\"],#chat_off button[aria-label=\"Bad response\"]').length===0"
  )))
  check("both paste/drop image payloads reach R intact", wait_for(
    "document.querySelector('#chat_off [data-role=assistant]')?.textContent.includes('ATT_COUNT=2 ATT_COMPLETE=TRUE')",
    5
  ))
  check("sent image attachments leave the composer", wait_for(
    "document.querySelectorAll('#chat_off .aui-composer-attachments .aui-attachment-root').length===0",
    5
  ))

  check("first queued scenario turn submitted", send_message("#chat_on", "queue first"))
  check("unfinished reply exposes the queue button", wait_for(
    "document.querySelector('#chat_on .aui-composer-queue-btn') && document.querySelector('#chat_on').textContent.includes('ON_QUEUE_FIRST_STARTED')",
    5
  ))
  users_before_queue <- value("document.querySelectorAll('#chat_on [data-role=user]').length")
  check("queue draft composer focused", click_element("#chat_on .aui-lexical-input[contenteditable=true]"))
  browser$Input$insertText(text = "queue second")
  check("queue action clicked", click_element("#chat_on .aui-composer-queue-btn"))
  check("enqueue clears only the draft", wait_for(
    "!document.querySelector('#chat_on .aui-lexical-input[contenteditable=true]')?.textContent.trim()",
    5
  ))
  check("queued message does not run before current completion", isTRUE(value(sprintf(
    "document.querySelectorAll('#chat_on [data-role=user]').length===%d && !document.querySelector('#chat_on').textContent.includes('ON_QUEUE_FIRST_DONE')",
    users_before_queue
  ))))
  check("synthetic first turn is explicitly completed", click_element("#release_queue"))
  check("queued message is automatically sent exactly once", wait_for(sprintf(
    paste0(
      "document.querySelectorAll('#chat_on [data-role=user]').length===%d && ",
      "[...document.querySelectorAll('#chat_on [data-role=assistant]')].some(e=>",
      "e.textContent.includes('ON_RUN=5 RELOAD=FALSE')&&e.textContent.includes('queue second'))"
    ),
    users_before_queue + 1L
  ), 10))
  check("first reply remains complete before the queued reply", isTRUE(value(
    "(()=>{const a=[...document.querySelectorAll('#chat_on [data-role=assistant]')];return a.at(-2)?.textContent.includes('ON_QUEUE_FIRST_DONE')&&a.at(-1)?.textContent.includes('queue second')})()"
  )))

  Sys.sleep(0.5)
  check(
    "no browser console errors", length(console_errors) == 0L,
    paste(head(console_errors, 3L), collapse = " | ")
  )
  check(
    "no browser runtime exceptions", length(runtime_exceptions) == 0L,
    paste(head(runtime_exceptions, 3L), collapse = " | ")
  )
  check(
    "no browser network failures", length(network_failures) == 0L,
    paste(head(network_failures, 3L), collapse = " | ")
  )

  if (length(failures)) {
    cat("APP_STDERR_TAIL\n")
    cat(tail(readLines(log_err, warn = FALSE), 20L), sep = "\n")
    stop("P1 Chromium verification failed: ", paste(failures, collapse = ", "))
  }
  cleanup()
  cat("P1_CHROMIUM_VERIFY_DONE\n")
}
main()
