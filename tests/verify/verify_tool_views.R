suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9341L
unlink(c("/tmp/aui-tv.out", "/tmp/aui-tv.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/tool_views_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-tv.out", stderr = "/tmp/aui-tv.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-tv.err") && any(grepl("Listening on", readLines("/tmp/aui-tv.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-tv.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 720, height = 900)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 15, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE); p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE
}
press_key <- function(key, code, vk) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk)
  browser$Input$dispatchKeyEvent(type = "keyUp",   key = key, code = code, windowsVirtualKeyCode = vk)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
click_sel(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.35)
browser$Input$insertText(text = "go"); Sys.sleep(0.25)
press_key("Enter", "Enter", 13L); Sys.sleep(0.3)

chk("tool cards rendered (arg views present)", wait_for("document.querySelectorAll('[data-arg-view]').length>=5", 15),
    value("document.querySelectorAll('[data-arg-view]').length+''"))

# Edit -> diff
chk("Edit renders a diff view", isTRUE(value("!!document.querySelector('[data-arg-view=\"diff\"]')")))

# Bash -> code(bash) with the command text
chk("Bash renders a bash code block", isTRUE(value("!!document.querySelector('[data-arg-view=\"code\"][data-arg-lang=\"bash\"]')")))
chk("Bash code block shows the command (not JSON)",
    isTRUE(value("(document.querySelector('[data-arg-lang=\"bash\"]')?.textContent||'').includes('ls -la /tmp')")),
    value("(document.querySelector('[data-arg-lang=\"bash\"]')?.textContent||'').slice(0,40)"))

# Write -> generic Markdown view, Source by default for non-Markdown files.
chk("Write renders generic Markdown view in Source mode", isTRUE(value(
  "!!document.querySelector('[data-arg-view=\"markdown\"][data-markdown-mode=\"source\"] [data-source-language=\"python\"]')"
)))
chk("Write Source shows the exact content",
    isTRUE(value("(document.querySelector('[data-source-language=\"python\"]')?.textContent||'')==='print(1)'")))
chk("Write offers Preview as Markdown", isTRUE(value(
  "Array.from(document.querySelectorAll('[data-arg-view=\"markdown\"] button')).some(b=>(b.innerText||'').trim()==='Preview as Markdown')"
)))

# run_r -> code(r), clean R (no JSON {\"code\":...} wrapper)
chk("run_r renders an R code block", isTRUE(value("!!document.querySelector('[data-arg-view=\"code\"][data-arg-lang=\"r\"]')")))
chk("run_r shows clean R code (mean(y), no JSON key)",
    isTRUE(value("(function(){var e=document.querySelector('[data-arg-lang=\"r\"]');if(!e)return false;var t=e.textContent||'';return t.includes('mean(y)') && !t.includes('\"code\"');})()")),
    value("(document.querySelector('[data-arg-lang=\"r\"]')?.textContent||'').slice(0,40)"))

# unknown -> json fallback
chk("unknown tool falls back to JSON view", isTRUE(value("!!document.querySelector('[data-arg-view=\"json\"]')")))
chk("code views count == 2 (bash+r; Write is generic Markdown)",
    isTRUE(value("document.querySelectorAll('[data-arg-view=\"code\"]').length===2")),
    value("document.querySelectorAll('[data-arg-view=\"code\"]').length+''"))

# Phase 2: TodoWrite -> checklist
chk("TodoWrite renders a todos checklist", isTRUE(value("!!document.querySelector('[data-arg-view=\"todos\"]')")))
chk("todo items carry status", isTRUE(value("!!document.querySelector('[data-todo-status=\"completed\"]') && !!document.querySelector('[data-todo-status=\"in_progress\"]')")))
chk("todo shows content text", isTRUE(value("(document.querySelector('[data-arg-view=\"todos\"]')?.textContent||'').includes('write tests')")))

# Phase 2: Grep -> query summary
chk("Grep renders a query view", isTRUE(value("!!document.querySelector('[data-arg-view=\"query\"]')")))
chk("Grep query has pattern field", isTRUE(value("(document.querySelector('[data-query-field=\"pattern\"]')?.textContent||'').includes('TODO')")))

# Phase 2: WebFetch -> query with url link
chk("WebFetch url renders as a link", isTRUE(value("(function(){var e=document.querySelector('[data-query-field=\"url\"] a');return !!e && (e.getAttribute('href')||'').includes('example.com') && e.getAttribute('target')==='_blank';})()")))

# Phase 3: run_r text result -> console (monospace, plain text, not JSON)
chk("run_r result renders as console text (not JSON)",
    isTRUE(value("(function(){var els=document.querySelectorAll('[data-result-view=\"console\"]');for(var i=0;i<els.length;i++){var t=els[i].textContent||'';if(t.includes('[1] 2') && !t.includes('{'))return true;}return false;})()")))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("TOOL_VIEWS_VERIFY_DONE\n")
