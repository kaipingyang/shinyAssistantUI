#!/usr/bin/env Rscript
# 抓"敲字时到底是谁把布局弄脏的":记录 viewport style 的具体变化,
# 并劫持布局读取 API 统计每次击键触发了多少次强制同步布局。
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("CULPRIT_PORT", "9320"))

p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = "300", SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/cp.o", stderr = "/tmp/cp.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/cp.e"), 10), sep="\n"); quit(status=1) }

b <- chromote::ChromoteSession$new()
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(3)

for (i in 1:20) {
  r <- ev("(function(){var items=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]'));var it=items.find(e=>/Synthetic Big History/.test(e.innerText));if(!it)return null;var b=it.getBoundingClientRect();return JSON.stringify({x:b.x+20,y:b.y+b.height/2});})()")
  if (!is.na(r) && !is.null(r)) break
  Sys.sleep(0.5)
}
xy <- jsonlite::fromJSON(r)
b$Input$dispatchMouseEvent(type="mousePressed", x=xy$x, y=xy$y, button="left", clickCount=1)
b$Input$dispatchMouseEvent(type="mouseReleased", x=xy$x, y=xy$y, button="left", clickCount=1)
prev <- -1; for (i in 1:60) { Sys.sleep(0.3); now <- as.integer(ev("document.querySelectorAll('*').length")); if (identical(now, prev)) break; prev <- now }
cat("历史挂载完成, DOM 节点 =", prev, "\n")

# 劫持布局读取 API,记录调用者栈顶几帧;同时记录 viewport style 的新旧值。
ev("
window.__forced = { reads: [], styles: [] };
(function(){
  const vp = document.querySelector('[data-slot=aui_thread-viewport]');
  if (!vp) return;
  window.__vp = vp;

  const record = (api) => {
    const stack = (new Error()).stack || '';
    const frames = stack.split('\\n').slice(2, 5).map(s => s.trim()).join(' | ');
    window.__forced.reads.push({ api, frames });
  };

  // 劫持最常见的强制同步布局读取入口
  const protoEl = Element.prototype;
  const origRect = protoEl.getBoundingClientRect;
  protoEl.getBoundingClientRect = function(){ record('getBoundingClientRect'); return origRect.call(this); };
  for (const prop of ['scrollHeight','clientHeight','scrollTop','offsetHeight','offsetTop']) {
    const desc = Object.getOwnPropertyDescriptor(protoEl, prop)
              || Object.getOwnPropertyDescriptor(HTMLElement.prototype, prop);
    if (!desc || !desc.get) continue;
    const target = Object.getOwnPropertyDescriptor(protoEl, prop) ? protoEl : HTMLElement.prototype;
    Object.defineProperty(target, prop, {
      configurable: true, enumerable: desc.enumerable,
      get: function(){ record(prop); return desc.get.call(this); },
      set: desc.set
    });
  }

  new MutationObserver((recs) => {
    for (const r of recs) {
      if (r.attributeName !== 'style') continue;
      if (window.__forced.styles.length >= 12) break;
      window.__forced.styles.push({
        slot: (r.target.getAttribute && r.target.getAttribute('data-slot')) || r.target.nodeName,
        old: r.oldValue, now: r.target.getAttribute('style')
      });
    }
  }).observe(vp, { attributes: true, attributeFilter: ['style'], attributeOldValue: true, subtree: false });
})();
")

ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el)el.focus();return !!el;})()")
Sys.sleep(0.5)
ev("window.__forced.reads=[]; window.__forced.styles=[];")

for (ch in c("a","b","c")) { b$Input$insertText(text = ch); Sys.sleep(0.25) }
Sys.sleep(1)

n <- as.integer(ev("window.__forced.reads.length"))
cat(sprintf("\n=== 敲 3 个字符,触发布局读取 %d 次 ===\n", n))
cat("按 API 分组:\n")
cat(ev("JSON.stringify(window.__forced.reads.reduce((m,r)=>{m[r.api]=(m[r.api]||0)+1;return m;},{}),null,1)"), "\n")
cat("\n调用来源 top5 (栈帧):\n")
cat(ev("JSON.stringify(Object.entries(window.__forced.reads.reduce((m,r)=>{const k=r.api+' <- '+r.frames;m[k]=(m[k]||0)+1;return m;},{})).sort((a,b)=>b[1]-a[1]).slice(0,5),null,1)"), "\n")
cat("\nviewport style 变化:\n")
cat(ev("JSON.stringify(window.__forced.styles,null,1)"), "\n")

b$close(); p$kill()
cat("CULPRIT_DONE\n")
