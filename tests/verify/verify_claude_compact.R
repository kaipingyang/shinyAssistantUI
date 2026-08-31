suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

project <- normalizePath(".", winslash = "/", mustWork = TRUE)
port <- 9662L
stdout_path <- "/tmp/aui-claude-compact.out"
stderr_path <- "/tmp/aui-claude-compact.err"
unlink(c(stdout_path, stderr_path))
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(project, port) {
    setwd(project)
    readRenviron(file.path(project, ".Renviron"))
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp(
      "tests/verify/claude_compact_app.R",
      host = "127.0.0.1",
      port = port,
      launch.browser = FALSE
    )
  },
  args = list(project = project, port = port),
  stdout = stdout_path,
  stderr = stderr_path
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(240L)) {
  if (!app$is_alive()) break
  if (file.exists(stderr_path) &&
      any(grepl("Listening on", readLines(stderr_path, warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) {
  cat(tail(readLines(stderr_path, warn = FALSE), 30L), sep = "\n")
  stop("Claude compact fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage",
  "--no-sandbox",
  "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 900, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    console_errors <<- c(console_errors, "console.error")
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  console_errors <<- c(console_errors, "Runtime.exceptionThrown")
})
value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 30, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
send_text <- function(text) {
  editor <- ".aui-lexical-input[contenteditable='true']"
  if (!wait_for(sprintf("!!document.querySelector(%s)", toJSON(editor, auto_unbox = TRUE)), 20)) {
    return(FALSE)
  }
  value(sprintf("document.querySelector(%s).focus(); true", toJSON(editor, auto_unbox = TRUE)))
  browser$Input$insertText(text = text)
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  TRUE
}
body_excludes <- function(text) {
  script <- sprintf(
    "!(document.body.innerText||'').includes(%s)",
    toJSON(text, auto_unbox = TRUE)
  )
  isTRUE(value(script))
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed widget mounted", wait_for("!!document.querySelector('.aui-root')", 30))
check("Shiny websocket connected", wait_for(
  "!!window.Shiny && !!Shiny.shinyapp && !!Shiny.shinyapp.$socket && Shiny.shinyapp.$socket.readyState===1",
  30
))

safe_prompt <- paste(
  "Use the Glob tool to inspect the current temporary working directory.",
  "Then reply with the word READY."
)
check("real composer accepted safe tool prompt", send_text(safe_prompt))
check("real provider turn reached a safe terminal state", wait_for(
  "(document.body.innerText||'').includes('READY') || (document.body.innerText||'').includes('Upstream protocol error')",
  150
))
check("real provider turn stopped running", wait_for(
  "!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')",
  30
))
check("course_status marker is absent from rendered UI", body_excludes("course_status"))
check("pseudo tool-call prose is absent from rendered UI", body_excludes("call <invoke"))

compact_editor <- ".aui-lexical-input[contenteditable='true']"
check("composer focused for exact /compact", isTRUE(value(sprintf(
  "document.querySelector(%s).focus(); true", toJSON(compact_editor, auto_unbox = TRUE)
))))
browser$Input$insertText(text = "/compact")
Sys.sleep(0.4)
browser$Input$dispatchKeyEvent(
  type = "keyDown", key = "Escape", code = "Escape", windowsVirtualKeyCode = 27L
)
browser$Input$dispatchKeyEvent(
  type = "keyUp", key = "Escape", code = "Escape", windowsVirtualKeyCode = 27L
)
Sys.sleep(0.2)
browser$Input$dispatchKeyEvent(
  type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
)
browser$Input$dispatchKeyEvent(
  type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
)
compact_running <- wait_for(
  "!!document.querySelector('[data-slot=action-progress][data-action-kind=compact][data-action-state=running]')",
  10, interval = 0.02
)
check("structured compact running phase appeared", compact_running)
if (compact_running) {
  check("compact uses an indeterminate bar", isTRUE(value(
    "!!document.querySelector('[data-slot=action-progress] [data-indeterminate=true]')"
  )))
  check("compact progress shows elapsed time without a percentage", isTRUE(value(
    "(function(){const t=document.querySelector('[data-slot=action-progress]')?.innerText||'';return /\\d+s elapsed/.test(t) && !/\\d+%/.test(t)})()"
  )))
  check("compact blocks the current composer", isTRUE(value(
    "document.querySelector('[data-slot=aui_composer-shell]')?.getAttribute('data-blocked')==='true' && document.querySelector('.aui-lexical-input')?.getAttribute('contenteditable')==='false'"
  )))
  check("compact does not expose AI Stop semantics", isTRUE(value(
    "!!document.querySelector('.aui-composer-compact-blocked') && !document.querySelector('.aui-composer-cancel')"
  )))
}
check("/compact action bubble appeared", wait_for(
  "Array.from(document.querySelectorAll('[data-role=user]')).some(x=>(x.innerText||'').includes('/compact'))",
  20
))
compact_settled <- wait_for(paste0(
  "(function(){const t=document.body.innerText||'';return ",
  "t.includes('Conversation compacted')||t.includes('No active session to compact')||",
  "t.includes('Compact failed')||t.includes('Action failed')||t.includes('Compact timed out')})()"
), 200)
compact_state <- value(paste0(
  "(document.body.innerText||'').split('\\n')",
  ".filter(x=>/compact/i.test(x)).slice(-6).join(' | ')"
))
check("/compact produced a terminal action result", compact_settled, compact_state)
check("/compact reached successful terminal ack",
      isTRUE(value("(document.body.innerText||'').includes('Conversation compacted')")),
      compact_state)
check("compact terminal data UI is complete and non-animating", isTRUE(value(
  "!!document.querySelector('[data-slot=action-progress][data-action-state=complete]') && !document.querySelector('[data-slot=action-progress] [data-indeterminate=true]')"
)))
check("composer is restored after compact", isTRUE(value(
  "document.querySelector('[data-slot=aui_composer-shell]')?.getAttribute('data-blocked')==='false' && document.querySelector('.aui-lexical-input')?.getAttribute('contenteditable')==='true' && !!document.querySelector('.aui-composer-send')"
)))
check("compact progress no longer remains", body_excludes("Compacting conversation"))
check("root remains mounted after compact", isTRUE(value("!!document.querySelector('.aui-root')")))
check("websocket remains connected after compact", isTRUE(value(
  "!!Shiny.shinyapp.$socket && Shiny.shinyapp.$socket.readyState===1"
)))

# Reload exercises persisted action/history rendering rather than only live updates.
browser$Page$reload()
browser$Page$loadEventFired()
check("widget remounted from history", wait_for("!!document.querySelector('.aui-root')", 30))
check("compacted terminal ack restored from history", wait_for(
  "(document.body.innerText||'').includes('Conversation compacted')",
  30
))
check("restored compact is terminal and never animates", isTRUE(value(
  "!!document.querySelector('[data-slot=action-progress][data-action-state=complete]') && !document.querySelector('[data-slot=action-progress] [data-indeterminate=true]')"
)))
check("restored history does not block composer", isTRUE(value(
  "document.querySelector('[data-slot=aui_composer-shell]')?.getAttribute('data-blocked')==='false' && document.querySelector('.aui-lexical-input')?.getAttribute('contenteditable')==='true'"
)))
check("restored history has no leaked provider marker", body_excludes("course_status"))
check("no browser console errors or runtime exceptions", length(console_errors) == 0L,
      if (length(console_errors)) paste(unique(console_errors), collapse = ", ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CLAUDE_COMPACT_PROTOCOL_VERIFY_DONE\n")
