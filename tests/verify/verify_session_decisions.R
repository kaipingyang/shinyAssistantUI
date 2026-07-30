# Bug a/c 无头验证:打开历史 session,工具卡回填 ✓ Approved / ✕ Denied,且不崩。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- 9763L
p <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/session_decisions_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/sd.o", stderr = "/tmp/sd.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE); Sys.sleep(10)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/sd.e"), 10), sep = "\n"); quit(status = 1) }

errs <- c()
b <- chromote::ChromoteSession$new()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error"))
  errs <<- c(errs, paste(sapply(m$args, function(a) a$value %||% a$description %||% ""), collapse = " ")))
b$Runtime$exceptionThrown(callback_ = function(m)
  errs <<- c(errs, paste("EXC:", m$exceptionDetails$exception$description %||% m$exceptionDetails$text %||% "")))
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)

b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(5)

# 等侧栏历史 session 出现,点开它 → 触发 on_session_load 下发 canned 历史线程
ok_sidebar <- FALSE
for (i in 1:15) { Sys.sleep(1); if (isTRUE(ev("!!document.querySelector('[data-slot=aui_thread-list-item]')"))) { ok_sidebar <- TRUE; break } }
cat(sprintf("[%s] history session appears in sidebar\n", if (ok_sidebar) "PASS" else "FAIL"))
# 点"History with approvals"那一项(而非默认的 New chat 项)→ 触发 on_session_load。
r <- ev("(function(){var its=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];var it=its.find(e=>/History/.test(e.innerText));if(!it)return null;var b=it.getBoundingClientRect();return JSON.stringify({x:b.x+20,y:b.y+b.height/2})})()")
if (!is.na(r) && !is.null(r)) {
  xy <- jsonlite::fromJSON(r)
  b$Input$dispatchMouseEvent(type = "mousePressed", x = xy$x, y = xy$y, button = "left", clickCount = 1)
  b$Input$dispatchMouseEvent(type = "mouseReleased", x = xy$x, y = xy$y, button = "left", clickCount = 1)
}
Sys.sleep(4)

# 展开工具卡(可能默认折叠)——点所有 tool-call header 确保决策指示可见
ev("(function(){document.querySelectorAll('[data-slot=aui_tool-call],[data-slot^=aui_tool]').forEach(function(e){var b=e.querySelector('button');if(b)b.click()});return true})()")
Sys.sleep(1)

denied <- ev("!!document.querySelector('[data-approval-result=denied]')")
approved <- ev("!!document.querySelector('[data-approval-result=approved]')")
body <- ev("document.body.innerText") %||% ""
txt_denied <- grepl("Denied", body, fixed = TRUE)
txt_appr   <- grepl("Approved", body, fixed = TRUE)

cat(sprintf("[%s] denied card restored (data-approval-result=denied)\n", if (isTRUE(denied)) "PASS" else "FAIL"))
cat(sprintf("[%s] approved card restored (data-approval-result=approved)\n", if (isTRUE(approved)) "PASS" else "FAIL"))
cat(sprintf("[%s] '✕ Denied' / '✓ Approved' text present (denied=%s approved=%s)\n",
            if (txt_denied && txt_appr) "PASS" else "FAIL", txt_denied, txt_appr))

react31 <- any(grepl("error #31|not valid as a React child|Minified React error", errs))
cat(sprintf("[%s] no React crash on history render\n", if (!react31) "PASS" else "FAIL"))
cat(sprintf("[%s] no browser console errors (%d)\n", if (length(errs) == 0) "PASS" else "FAIL", length(errs)))
if (length(errs)) cat(head(unique(errs), 4), sep = "\n")

b$close(); p$kill(); system("rm -f /tmp/sd.*")
cat("SESSION_DECISIONS_DONE\n")
