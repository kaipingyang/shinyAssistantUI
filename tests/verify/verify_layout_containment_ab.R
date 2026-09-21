#!/usr/bin/env Rscript
# 验证"打字卡是 CSS 布局耦合"而非 JS 读布局:
# 同一页面内先测基线,再注入 CSS 切断 composer 与消息列表的布局耦合,再测。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("CONTAIN_PORT", "9350"))

p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = "300", SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/ct.o", stderr = "/tmp/ct.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/ct.e"), 10), sep="\n"); quit(status=1) }

b <- chromote::ChromoteSession$new()
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(3)

ev("window.__probe={keyTimes:[],longtasks:[]};try{new PerformanceObserver(l=>{for(const e of l.getEntries())window.__probe.longtasks.push(e.duration)}).observe({entryTypes:['longtask']})}catch(e){}")

for (i in 1:20) {
  r <- ev("(function(){var items=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'));var it=items.find(e=>/Synthetic Big History/.test(e.innerText));if(!it)return null;var b=it.getBoundingClientRect();return JSON.stringify({x:b.x+20,y:b.y+b.height/2});})()")
  if (!is.na(r) && !is.null(r)) break
  Sys.sleep(0.5)
}
xy <- jsonlite::fromJSON(r)
b$Input$dispatchMouseEvent(type="mousePressed", x=xy$x, y=xy$y, button="left", clickCount=1)
b$Input$dispatchMouseEvent(type="mouseReleased", x=xy$x, y=xy$y, button="left", clickCount=1)
prev <- -1; for (i in 1:60) { Sys.sleep(0.3); now <- as.integer(ev("document.querySelectorAll('*').length")); if (identical(now,prev)) break; prev <- now }
cat("DOM 节点 =", prev, "\n")

focus <- function() ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el){el.focus();return true}return false})()")
clear_input <- function() ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]');if(el)el.innerHTML='<p><br></p>';return true})()")

measure <- function(label, text) {
  focus(); Sys.sleep(0.3)
  ev("window.__probe.keyTimes=[];window.__probe.longtasks=[];window.__t0=performance.now();")
  for (ch in strsplit(text, "")[[1]]) {
    ev("(function(){const t=performance.now();requestAnimationFrame(()=>window.__probe.keyTimes.push(performance.now()-t));})()")
    b$Input$insertText(text = ch); Sys.sleep(0.01)
  }
  Sys.sleep(0.3)
  total <- ev("performance.now()-window.__t0")
  frames <- as.numeric(unlist(jsonlite::fromJSON(ev("JSON.stringify(window.__probe.keyTimes)"))))
  lts <- as.numeric(unlist(jsonlite::fromJSON(ev("JSON.stringify(window.__probe.longtasks)"))))
  cat(sprintf("[%-28s] 总耗时=%6.0fms  单帧p95=%5.1fms  最大=%5.1fms  longtasks=%d\n",
              label, total, quantile(frames, 0.95, na.rm=TRUE), max(frames,0), length(lts)))
  clear_input(); Sys.sleep(0.3)
  invisible(list(total=total, p95=quantile(frames,0.95,na.rm=TRUE)))
}

cat("\n=== 同一页面内的 A/B 对照 ===\n")
measure("基线(现状)", "hello world typing test")

# 干预 1:给消息列表容器加 contain,阻止其参与祖先布局重算
ev("(function(){var s=document.createElement('style');s.id='probe-contain';s.textContent='[data-slot=aui_thread-viewport]{contain:layout paint;}';document.head.appendChild(s);return true})()")
Sys.sleep(0.5)
measure("+ viewport contain", "hello world typing test")

# 干预 2:再把 composer 高度固定,彻底切断"输入->高度变化"这条路径
ev("(function(){var s=document.createElement('style');s.id='probe-fixed';s.textContent='.aui-composer-input,.aui-lexical-input{height:40px!important;min-height:40px!important;max-height:40px!important;overflow:hidden!important;}';document.head.appendChild(s);return true})()")
Sys.sleep(0.5)
measure("+ composer 固定高度", "hello world typing test")

# 干预 3:直接把消息列表隐藏(极端对照,确认成本确实来自它)
ev("(function(){var s=document.createElement('style');s.id='probe-hide';s.textContent='[data-slot=aui_thread-viewport]>*{display:none!important;}';document.head.appendChild(s);return true})()")
Sys.sleep(0.5)
measure("+ 消息列表整个隐藏", "hello world typing test")

b$close(); p$kill()
cat("CONTAIN_AB_DONE\n")
