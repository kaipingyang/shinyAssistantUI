suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9717L
unlink(c("/tmp/aui-strict.out", "/tmp/aui-strict.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/strict_mode_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-strict.out", stderr = "/tmp/aui-strict.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(120)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-strict.err") && any(grepl("Listening on", readLines("/tmp/aui-strict.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-strict.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 760, height = 900)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 15, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))

# 权限选择器存在
chk("permission mode selector present", wait_for("!!document.querySelector('select[aria-label=\"Permission mode\"]')", 15))
# Strict(askAll)选项存在,文案 Strict
chk("Strict (askAll) option present with label 'Strict'",
    isTRUE(value("(function(){var o=document.querySelector('select[aria-label=\"Permission mode\"] option[value=\"askAll\"]');return !!o && (o.textContent||'').trim()==='Strict';})()")),
    value("Array.from(document.querySelectorAll('select[aria-label=\"Permission mode\"] option')).map(o=>o.value).join(',')"))

# Strict 置于第一
chk("Strict is the FIRST option",
    isTRUE(value("document.querySelector('select[aria-label=\"Permission mode\"] option')?.value==='askAll'")),
    value("document.querySelector('select[aria-label=\"Permission mode\"] option')?.value"))

# YOLO 选项存在
chk("YOLO (yolo) option present with label 'YOLO'",
    isTRUE(value("(function(){var o=document.querySelector('select[aria-label=\"Permission mode\"] option[value=\"yolo\"]');return !!o && (o.textContent||'').trim()==='YOLO';})()")))

# 选中 Strict → 往返
value("(function(){var s=document.querySelector('select[aria-label=\"Permission mode\"]');s.value='askAll';s.dispatchEvent(new Event('change',{bubbles:true}));return true;})()")
chk("selecting Strict round-trips to value 'askAll'",
    wait_for("document.querySelector('select[aria-label=\"Permission mode\"]').value==='askAll'", 12),
    value("document.querySelector('select[aria-label=\"Permission mode\"]').value"))

# 选中 YOLO → 往返(客户端 Set 放行 + R action 回传)
value("(function(){var s=document.querySelector('select[aria-label=\"Permission mode\"]');s.value='yolo';s.dispatchEvent(new Event('change',{bubbles:true}));return true;})()")
chk("selecting YOLO round-trips to value 'yolo'",
    wait_for("document.querySelector('select[aria-label=\"Permission mode\"]').value==='yolo'", 12),
    value("document.querySelector('select[aria-label=\"Permission mode\"]').value"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("STRICT_MODE_VERIFY_DONE\n")
