#!/usr/bin/env Rscript
# 定性实验:加载大历史后敲一个字符,消息列表是否发生 DOM 变更。
#   有变更 -> React 把消息列表一起重渲染了(可用 memo 化修,收益大、改动小)
#   无变更 -> 纯浏览器重排(必须上虚拟化)
suppressMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- as.integer(Sys.getenv("RERENDER_PORT", "9291"))

p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron"))
  suppressMessages(library(shiny))
  Sys.setenv(SYNTH_HISTORY_N = "300", SYNTH_HISTORY_KIND = "mixed")
  shiny::runApp("tests/verify/typing_lag_synthetic_history_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/rr.o", stderr = "/tmp/rr.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(6)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/rr.e"), 10), sep = "\n"); quit(status = 1) }

b <- chromote::ChromoteSession$new()
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(3)

# 点开合成大历史
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

# 在消息列表容器上挂 MutationObserver,并单独统计 composer 子树的变更作为对照
ev("
window.__mut = { list: 0, listNodes: 0, composer: 0, records: [] };
(function(){
  const vp = document.querySelector('[data-slot=aui_thread-viewport]')
          || document.querySelector('.aui-thread-viewport')
          || document.querySelector('[data-slot=aui_thread-root]');
  const comp = document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')
            || document.querySelector('[contenteditable=\"true\"]');
  window.__mutTargets = { vp: !!vp, comp: !!comp,
    vpSlot: vp ? (vp.getAttribute('data-slot') || vp.className) : null };
  if (vp) {
    new MutationObserver((recs) => {
      for (const r of recs) {
        // 落在 composer 子树内的变更不算消息列表
        if (comp && (comp.contains(r.target) || r.target === comp)) continue;
        window.__mut.list++;
        window.__mut.listNodes += r.addedNodes.length + r.removedNodes.length;
        if (window.__mut.records.length < 8) {
          window.__mut.records.push({
            type: r.type,
            target: (r.target.getAttribute && r.target.getAttribute('data-slot')) || r.target.nodeName,
            attr: r.attributeName || null,
            added: r.addedNodes.length, removed: r.removedNodes.length
          });
        }
      }
    }).observe(vp, { childList: true, subtree: true, attributes: true, characterData: true });
  }
  if (comp) {
    new MutationObserver((recs) => { window.__mut.composer += recs.length; })
      .observe(comp, { childList: true, subtree: true, attributes: true, characterData: true });
  }
})();
")
cat("观察目标:", ev("JSON.stringify(window.__mutTargets)"), "\n")

ev("(function(){var el=document.querySelector('.aui-lexical-input[contenteditable=\"true\"]')||document.querySelector('[contenteditable=\"true\"]');if(el)el.focus();return !!el;})()")
Sys.sleep(0.5)
ev("window.__mut.list=0; window.__mut.listNodes=0; window.__mut.composer=0; window.__mut.records=[];")

# 只敲 5 个字符,看消息列表是否被动
for (ch in c("a","b","c","d","e")) { b$Input$insertText(text = ch); Sys.sleep(0.15) }
Sys.sleep(1)

res <- jsonlite::fromJSON(ev("JSON.stringify(window.__mut)"))
cat("\n=== 敲 5 个字符后 ===\n")
cat(sprintf("composer 子树变更次数 : %d  (预期:应该有,这是正常的)\n", res$composer))
cat(sprintf("消息列表变更次数      : %d  (关键指标)\n", res$list))
cat(sprintf("消息列表增删节点数    : %d\n", res$listNodes))
if (length(res$records)) {
  cat("消息列表变更样本:\n")
  print(res$records)
}
cat("\n=== 判定 ===\n")
if (!is.na(res$list) && res$list > 0) {
  cat("消息列表在敲字时发生了 DOM 变更 -> React 连带重渲染了消息列表。\n")
  cat("修法方向:memo 化 / 隔离 composer 状态,不必上虚拟化。\n")
} else {
  cat("消息列表无 DOM 变更 -> 纯浏览器重排(样式/布局),React 没有重渲染。\n")
  cat("修法方向:需要虚拟化或 CSS contain 来减少重排范围。\n")
}
b$close(); p$kill()
cat("RERENDER_PROBE_DONE\n")
