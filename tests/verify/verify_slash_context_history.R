suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9188L
failures <- character()
unlink(c("/tmp/aui-slash-context-history.out", "/tmp/aui-slash-context-history.err"))

check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-42s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}

app <- callr::r_bg(
  function(project, port) {
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp(
      "tests/verify/slash_context_history_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  },
  args = list(project = project, port = port),
  stdout = "/tmp/aui-slash-context-history.out",
  stderr = "/tmp/aui-slash-context-history.err"
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)

for (i in seq_len(80)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-slash-context-history.err") &&
      any(grepl("Listening on", readLines("/tmp/aui-slash-context-history.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  cat(tail(readLines("/tmp/aui-slash-context-history.err", warn = FALSE), 20), sep = "\n")
  stop("Browser fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new()
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

console_errors <- character()
current_stage <- "boot"
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    text <- paste(vapply(message$args, function(arg) {
      as.character(arg$value %||% arg$description %||% "")
    }, character(1)), collapse = " ")
    console_errors <<- c(console_errors, paste(current_stage, "console:", text))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  console_errors <<- c(console_errors, paste(
    current_stage, "exception:", detail$exception$description %||% detail$text %||% "unknown"
  ))
})

value <- function(script) {
  response <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
  response$result$value
}
wait_for <- function(script, timeout = 8, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    answer <- tryCatch(value(script), error = function(e) FALSE)
    if (isTRUE(answer)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
key <- function(name, code, virtual_key, modifiers = 0L) {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = name, code = code,
    windowsVirtualKeyCode = as.integer(virtual_key), modifiers = as.integer(modifiers)
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = name, code = code,
    windowsVirtualKeyCode = as.integer(virtual_key), modifiers = as.integer(modifiers)
  )
}
focus_editor <- function() {
  value("(function(){const e=document.querySelector('.aui-lexical-input[contenteditable=true]');if(e)e.focus();return !!e})()")
}
clear_editor <- function() {
  focus_editor()
  key("a", "KeyA", 65L, modifiers = 2L)
  key("Backspace", "Backspace", 8L)
  Sys.sleep(0.1)
}
type_text <- function(text) {
  focus_editor()
  browser$Input$insertText(text = text)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
mounted <- wait_for("!!document.querySelector('.aui-root')", 12)
check("widget mounted", mounted)
if (!mounted) {
  cat("URL:", value("location.href"), "\n")
  cat("BODY:\n", value("document.body.innerText.slice(0,2000)"), "\n")
  cat("HTML:\n", value("document.documentElement.outerHTML.slice(0,3000)"), "\n")
  if (length(console_errors)) cat("CONSOLE:\n", paste(console_errors, collapse = "\n"), "\n")
  stop("Widget did not mount")
}
check("Lexical composer mounted", wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')"))
input_layout_json <- value("(function(){const s=document.querySelector('.aui-lexical-editor'),e=document.querySelector('.aui-lexical-input[contenteditable=true]'),p=document.querySelector('.aui-lexical-placeholder');if(!s||!e||!p)return null;const ss=getComputedStyle(s),es=getComputedStyle(e),ps=getComputedStyle(p),er=e.getBoundingClientRect(),pr=p.getBoundingClientRect(),sr=s.getBoundingClientRect();return JSON.stringify({shellPosition:ss.position,shellWidth:sr.width,editorWidth:er.width,borderStyle:es.borderStyle,borderTopWidth:es.borderTopWidth,outlineStyle:es.outlineStyle,placeholderPosition:ps.position,placeholderTop:pr.top,placeholderBottom:pr.bottom,editorTop:er.top,editorBottom:er.bottom})})()")
input_layout <- fromJSON(input_layout_json)
check("composer is one borderless input surface",
      identical(input_layout$shellPosition, "relative") &&
        (identical(input_layout$borderStyle, "none") || identical(input_layout$borderTopWidth, "0px")) &&
        input_layout$editorWidth >= input_layout$shellWidth - 25,
      sprintf("shell=%s %.1f editor=%.1f border=%s/%s",
              input_layout$shellPosition, input_layout$shellWidth, input_layout$editorWidth,
              input_layout$borderStyle, input_layout$borderTopWidth))
check("composer placeholder overlays the editor",
      identical(input_layout$placeholderPosition, "absolute") &&
        input_layout$placeholderTop < input_layout$editorBottom &&
        input_layout$placeholderBottom > input_layout$editorTop,
      sprintf("position=%s placeholder=%.1f..%.1f editor=%.1f..%.1f",
              input_layout$placeholderPosition, input_layout$placeholderTop,
              input_layout$placeholderBottom, input_layout$editorTop, input_layout$editorBottom))
Sys.sleep(0.5)
check("new session is not prewarmed", !isTRUE(value("!!document.querySelector('[data-slot=aui_warming]')")))

# A new blank session remains cold until its first real prompt.
current_stage <- "new-first-prompt"
value("window.__newWarmSeen=false;window.__newWarmTimer=setInterval(()=>{if(document.querySelector('[data-slot=aui_warming]'))window.__newWarmSeen=true},10);true")
type_text("first cold prompt")
key("Enter", "Enter", 13L)
check("new session first prompt completes", wait_for("document.body.innerText.includes('ECHO[first cold prompt]')", 10))
Sys.sleep(0.2)
check("new session first prompt showed warming", isTRUE(value("window.__newWarmSeen")))
check("new session warming disappears", !isTRUE(value("!!document.querySelector('[data-slot=aui_warming]')")))

# Open slash menu and validate real layout plus Escape.
current_stage <- "slash-layout-escape"
clear_editor(); type_text("/")
check("slash popover opens", wait_for("!!document.querySelector('.aui-slash-popover')"))
layout_json <- value("(function(){const p=document.querySelector('.aui-slash-popover'),e=document.querySelector('.aui-lexical-editor');if(!p||!e)return null;const a=p.getBoundingClientRect(),b=e.getBoundingClientRect();return JSON.stringify({pl:a.left,pw:a.width,pt:a.top,pb:a.bottom,el:b.left,ew:b.width,vw:innerWidth,vh:innerHeight})})()")
layout <- fromJSON(layout_json)
check("slash popover aligns with composer", abs(layout$pl - layout$el) <= 2 && abs(layout$pw - layout$ew) <= 2,
      sprintf("popover=%.1f/%.1f editor=%.1f/%.1f", layout$pl, layout$pw, layout$el, layout$ew))
check("slash popover is inside viewport", layout$pl >= 0 && layout$pt >= 0 && layout$pl + layout$pw <= layout$vw + 1 && layout$pb <= layout$vh + 1)
check("slash sections remain visible", isTRUE(value("!!document.querySelector('[data-trigger-section=Actions]') && !!document.querySelector('[data-trigger-section=\"Project Skills\"]')")))
# Keyboard highlight must auto-scroll the popover so the highlighted item stays in view.
current_stage <- "slash-highlight-scroll"
for (i in seq_len(12L)) { key("ArrowDown", "ArrowDown", 40L); Sys.sleep(0.03) }
Sys.sleep(0.1)
scroll_json <- value("(function(){const p=document.querySelector('.aui-slash-popover');if(!p)return null;const h=p.querySelector('[data-highlighted]');if(!h)return null;const a=p.getBoundingClientRect(),b=h.getBoundingClientRect();return JSON.stringify({pt:a.top,pb:a.bottom,ht:b.top,hb:b.bottom})})()")
scroll_rect <- if (is.null(scroll_json)) NULL else fromJSON(scroll_json)
check("highlighted slash item is scrolled into view",
      !is.null(scroll_rect) && scroll_rect$ht >= scroll_rect$pt - 1 && scroll_rect$hb <= scroll_rect$pb + 1,
      if (is.null(scroll_rect)) "no highlighted item" else sprintf("popover=%.1f..%.1f item=%.1f..%.1f", scroll_rect$pt, scroll_rect$pb, scroll_rect$ht, scroll_rect$hb))
key("Escape", "Escape", 27L)
check("Escape closes slash popover", wait_for("!document.querySelector('.aui-slash-popover')"))

# ArrowDown selects the second item (skill); Enter executes the highlighted result.
current_stage <- "slash-arrow-down-enter"
clear_editor(); type_text("/")
check("slash popover reopens", wait_for("!!document.querySelector('.aui-slash-popover')"))
key("ArrowDown", "ArrowDown", 40L)
Sys.sleep(0.08)
key("Enter", "Enter", 13L)
check("ArrowDown and Enter select skill", wait_for("!!document.querySelector('[data-directive-type=slash][data-directive-id=yourskill]')"))
type_text(" arrow-check")
key("Enter", "Enter", 13L)
check("ArrowDown-selected skill submits", wait_for("document.body.innerText.includes('ECHO[/yourskill arrow-check]')", 8))

# ArrowUp returns from the second item to the first action; Enter executes it.
current_stage <- "clear-arrow-down-skill"
clear_editor()
Sys.sleep(0.2)
current_stage <- "slash-arrow-up-context"
type_text("/")
check("slash popover opens for ArrowUp", wait_for("!!document.querySelector('.aui-slash-popover')"))
key("ArrowDown", "ArrowDown", 40L)
Sys.sleep(0.08)
key("ArrowUp", "ArrowUp", 38L)
Sys.sleep(0.08)
key("Enter", "Enter", 13L)
# 选中 action 现在与 skill 一致：先插入蓝色 directive chip（不立即执行）。
check("context action inserts a blue directive chip", wait_for("!!document.querySelector('[data-directive-type=slash-action][data-directive-id=context]')", 4))
context_chip_style <- value("(function(){const e=document.querySelector('[data-directive-type=slash-action][data-directive-id=context]');if(!e)return '';const s=getComputedStyle(e);return s.backgroundColor+'|'+s.color})()")
check("context action chip is visibly blue", grepl("^(oklch|rgb)\\(", context_chip_style) && !grepl("transparent|0, 0, 0, 0", context_chip_style), context_chip_style)
Sys.sleep(0.1)
# 提交（Enter）才路由到本地 action handler 执行。
key("Enter", "Enter", 13L)
check("submitting context chip executes the action", wait_for("document.body.innerText.includes('Estimated usage by category')", 8))
check("context heading renders", isTRUE(value("Array.from(document.querySelectorAll('h1')).some(x=>x.innerText==='Context Usage')")))
check("context category table renders", as.integer(value("document.querySelectorAll('table').length")) >= 1L)

# Tab completes the highlighted action into a blue chip (consistent with skills).
current_stage <- "slash-tab-completion"
context_count <- as.integer(value("Array.from(document.querySelectorAll('h1')).filter(x=>x.innerText==='Context Usage').length"))
clear_editor(); type_text("/")
check("slash popover opens for Tab", wait_for("!!document.querySelector('.aui-slash-popover')"))
key("Tab", "Tab", 9L)
check("Tab inserts action directive chip", wait_for("!!document.querySelector('[data-directive-type=slash-action][data-directive-id=context]')", 4))
check("Tab does not execute action", as.integer(value("Array.from(document.querySelectorAll('h1')).filter(x=>x.innerText==='Context Usage').length")) == context_count)
check("Tab completion closes slash popover", wait_for("!document.querySelector('.aui-slash-popover')"))

# Filtered Tab inserts the skill chip and keeps it in the composer for arguments.
current_stage <- "slash-tab-skill"
clear_editor(); type_text("/your")
check("filtered skill appears", wait_for("!!document.querySelector('[data-slash-cmd=yourskill]')"))
key("Tab", "Tab", 9L)
check("Tab inserts skill directive", wait_for("!!document.querySelector('[data-directive-type=slash][data-directive-id=yourskill]')"))
chip_style <- value("(function(){const e=document.querySelector('[data-directive-type=slash][data-directive-id=yourskill]');if(!e)return '';const s=getComputedStyle(e);return s.backgroundColor+'|'+s.color})()")
check("skill directive is visibly blue", grepl("^(oklch|rgb)\\(", chip_style) && !grepl("transparent|0, 0, 0, 0", chip_style), chip_style)
type_text(" argument-one")
key("Enter", "Enter", 13L)
check("skill arguments remain literal", wait_for("document.body.innerText.includes('ECHO[/yourskill argument-one]')", 8))

# History is lazy and paged: reading -> newest page -> restoring; older pages prepend on demand.
current_stage <- "history-load-warmup"
value("window.__historyTimeline=[];window.__historyFound=false;window.__historyWarm=false;window.__historyReading=false;window.__historyTimer=setInterval(()=>{const body=document.body.innerText;if(!window.__historyFound&&body.includes('HISTORICAL_FIXTURE_MESSAGE')){window.__historyFound=true;window.__historyTimeline.push('messages')}const r=!!document.querySelector('[data-slot=aui_history_reading]');if(r!==window.__historyReading){window.__historyReading=r;window.__historyTimeline.push(r?'reading:true':'reading:false')}const w=!!document.querySelector('[data-slot=aui_warming]');if(w!==window.__historyWarm){window.__historyWarm=w;window.__historyTimeline.push(w?'warming:true':'warming:false')}},10);true")
item_json <- value("(function(){const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(x=>x.innerText.includes('Fixture History'));if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2,visible:r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight})})()")
check("history item is visible", !is.null(item_json) && isTRUE(fromJSON(item_json)$visible))
point <- fromJSON(item_json)
browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
check("history reading indicator appears", wait_for("window.__historyTimeline.includes('reading:true')", 4))
check("newest history page loads after click", wait_for("document.body.innerText.includes('HISTORICAL_FIXTURE_MESSAGE')", 6))
check("oldest history is not in initial page", !isTRUE(value("document.body.innerText.includes('OLDER_FIXTURE_001')")))
check("history tool card restores collapsed", wait_for("document.body.innerText.includes('Read') && !document.body.innerText.includes('fixture tool result')", 6))
check("load older control appears", wait_for("!!document.querySelector('[data-slot=aui_load_older]')", 4))
value("document.querySelector('[data-slot=aui_load_older]').click(); true")
check("older history prepends on demand", wait_for("document.body.innerText.includes('OLDER_FIXTURE_001')", 6))
value("document.querySelector('[data-slot=tool-fallback-trigger]').click(); true")
check("tool result renders only after expand", wait_for("document.body.innerText.includes('fixture tool result')", 4))
check("history warming completes", wait_for("window.__historyTimeline.includes('warming:true') && window.__historyTimeline.includes('warming:false')", 8))
timeline <- fromJSON(value("JSON.stringify(window.__historyTimeline)"))
check("history reading and restore phases are both observed", all(c("reading:true", "reading:false", "messages", "warming:true", "warming:false") %in% timeline),
      paste(timeline, collapse = " -> "))
# resume 时 CLI 以 user 轮次写入的 <task-notification> 合成通知必须被显示层过滤，
# 真实的 user/assistant 消息仍保留。
check("synthetic task-notification is filtered from history",
      !isTRUE(value("document.body.innerText.includes('task-notification') || document.body.innerText.includes('__orphan_summary__') || document.body.innerText.includes('b4f7icfpc')")))
check("real messages around the notification are preserved",
      isTRUE(value("document.body.innerText.includes('REAL_USER_BEFORE_NOTIF') && document.body.innerText.includes('REAL_ASSISTANT_AFTER_NOTIF')")))

current_stage <- "history-continuation"
value("window.__continueWarmSeen=false;window.__continueTimer=setInterval(()=>{if(document.querySelector('[data-slot=aui_warming]'))window.__continueWarmSeen=true},10);true")
clear_editor(); type_text("continue history")
key("Enter", "Enter", 13L)
check("history continuation completes", wait_for("document.body.innerText.includes('ECHO[continue history]')", 8))
Sys.sleep(0.2)
check("history continuation has no cold start", !isTRUE(value("window.__continueWarmSeen")))

Sys.sleep(0.3)
check("no browser console errors or exceptions", length(console_errors) == 0L,
      if (length(console_errors)) paste(unique(console_errors), collapse = " | ") else "0 errors")
check("widget survives full scenario", isTRUE(value("!!document.querySelector('.aui-root')")))

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
unlink(c("/tmp/aui-slash-context-history.out", "/tmp/aui-slash-context-history.err"))
if (length(failures)) stop("Chromium verification failed: ", paste(failures, collapse = ", "))
cat("SLASH_CONTEXT_HISTORY_CHROMIUM_DONE\n")
