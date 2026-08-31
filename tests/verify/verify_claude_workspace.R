#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project_root <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
port <- 9327L
stdout_path <- "/tmp/claude-workspace-browser.out"
stderr_path <- "/tmp/claude-workspace-browser.err"
unlink(c(stdout_path, stderr_path))

app <- callr::r_bg(function(project_root, home_library, port) {
  .libPaths(c(home_library, .Library.site, .Library))
  setwd(project_root)
  suppressPackageStartupMessages({
    library(shiny)
    library(shinyAssistantUI)
  })
  cat("installed=", normalizePath(find.package("shinyAssistantUI")), "\n", sep = "")
  shiny::runApp(
    "tests/verify/claude_workspace_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project_root = project_root, home_library = home_library, port = port),
stdout = stdout_path, stderr = stderr_path)
on.exit({
  try(app$kill(), silent = TRUE)
  unlink(c(stdout_path, stderr_path))
}, add = TRUE)

for (i in seq_len(120L)) {
  if (!app$is_alive()) {
    cat(readLines(stderr_path, warn = FALSE), sep = "\n")
    stop("Workspace fixture exited during startup", call. = FALSE)
  }
  logs <- if (file.exists(stderr_path)) readLines(stderr_path, warn = FALSE) else character()
  if (any(grepl("Listening on", logs, fixed = TRUE))) break
  Sys.sleep(0.25)
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 1100, height = 760)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

browser_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) {
    text <- paste(vapply(event$args, function(arg) {
      as.character(arg$value %||% arg$description %||% "")
    }, character(1)), collapse = " ")
    browser_errors <<- c(browser_errors, paste0("console: ", text))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  browser_errors <<- c(
    browser_errors,
    paste0(
      "exception: ",
      event$exceptionDetails$exception$description %||%
        event$exceptionDetails$text %||% "unknown"
    )
  )
})

evaluate <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
  result$result$value
}
wait_for <- function(script, timeout = 15, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(evaluate(script), error = function(e) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
check <- function(label, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-48s %s\n", if (ok) "PASS" else "FAIL", label, detail))
  if (!ok) stop(label, call. = FALSE)
}
click_thread <- function(title) {
  encoded <- toJSON(title, auto_unbox = TRUE)
  script <- sprintf(
    "(()=>{const item=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes(%s));const trigger=item?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!trigger)return false;trigger.click();return true})()",
    encoded
  )
  check(paste("select", title), wait_for(script))
  Sys.sleep(0.25)
}
send_text <- function(text) {
  check("composer available", wait_for("!!document.querySelector('[contenteditable=true]')"))
  evaluate("document.querySelector('[contenteditable=true]').focus()")
  browser$Input$insertText(text = text)
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  Sys.sleep(0.15)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed widget mounted", wait_for("!!document.querySelector('.aui-root')", 20))
check(
  "four startup project groups rendered including empty E",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"])').length===4")
)
check(
  "project identities rendered",
  isTRUE(evaluate("(()=>{const p=[...document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"])')].map(x=>x.dataset.project);return ['/workspace/project-a','/workspace/project-b','/workspace/project-d','/workspace/project-e'].every(x=>p.includes(x))})()"))
)
check(
  "startup order pins current then uses recent activity and empty fallback",
  isTRUE(evaluate("(()=>{const p=[...document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"])')].map(x=>x.dataset.project);return JSON.stringify(p)===JSON.stringify(['/workspace/project-a','/workspace/project-d','/workspace/project-b','/workspace/project-e'])})()"))
)
check(
  "only current project starts expanded",
  isTRUE(evaluate("(()=>{const paths=['a','b','d','e'];const states=Object.fromEntries(paths.map(k=>{const h=document.querySelector(`[data-project=\"/workspace/project-${k}\"] [data-slot=aui_workspace-project-header]`);return [k,h?.getAttribute('aria-expanded')]}));return states.a==='true'&&states.b==='false'&&states.d==='false'&&states.e==='false'})()")),
  evaluate("JSON.stringify(Object.fromEntries(['a','b','d','e'].map(k=>[k,document.querySelector(`[data-project=\"/workspace/project-${k}\"] [data-slot=aui_workspace-project-header]`)?.getAttribute('aria-expanded')??null])))")
)
check(
  "Workspace removes the ambiguous global New Thread",
  isTRUE(evaluate("!document.querySelector('[data-slot=aui_thread-list-new]')"))
)
check(
  "Workspace exposes Collapse all folders",
  isTRUE(evaluate("document.querySelector('[data-slot=aui_workspace-collapse-all]')?.getAttribute('aria-label')==='Collapse all folders'"))
)
check(
  "every active folder has its own new-chat button",
  isTRUE(evaluate("(()=>{const groups=[...document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"])')];return groups.length===4&&groups.every(g=>!!g.querySelector('[data-slot=aui_workspace-project-new]'))})()"))
)
check(
  "empty project E remains actionable with count zero",
  isTRUE(evaluate("(()=>{const g=document.querySelector('[data-project=\"/workspace/project-e\"]');return g?.querySelector('[data-slot=aui_workspace-thread-count]')?.textContent==='0'&&!!g.querySelector('[data-slot=aui_workspace-project-new]')})()"))
)
check(
  "Workspace outer scrollbar has a stable dedicated gutter",
  isTRUE(evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const c=document.querySelector('[data-slot=aui_thread-list-outer-scroll-content]');const r=document.querySelector('[data-slot=aui_thread-list-root]');if(!o||!c||!r)return false;const os=getComputedStyle(o),cs=getComputedStyle(c),or=o.getBoundingClientRect(),rr=r.getBoundingClientRect();return os.overflowY==='scroll'&&os.scrollbarGutter.includes('stable')&&parseFloat(cs.paddingRight)>=11&&or.right-rr.right>=20})()"))
)
check(
  "open Beta without closing current Alpha folder",
  wait_for("(()=>{const a=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-a\"]');const b=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-b\"]');const ah=a?.querySelector('[data-slot=aui_workspace-project-header]');const bh=b?.querySelector('[data-slot=aui_workspace-project-header]');if(!ah||!bh)return false;if(bh.getAttribute('aria-expanded')==='false')bh.click();return ah.getAttribute('aria-expanded')==='true'&&bh.getAttribute('aria-expanded')==='true'&&!!a.querySelector('[data-slot=aui_workspace-project-threads]')&&!!b.querySelector('[data-slot=aui_workspace-project-threads]')})()")
)
check(
  "large project history has bounded vertical scroll",
  isTRUE(evaluate("(()=>{const g=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-a\"]');const b=g?.querySelector('[data-slot=aui_workspace-project-threads]');if(!b)return false;const y=getComputedStyle(b).overflowY;return (y==='auto'||y==='scroll')&&getComputedStyle(b).overscrollBehaviorY==='contain'&&b.scrollHeight>b.clientHeight+1})()"))
)
check(
  "large project history scrollTop moves",
  isTRUE(evaluate("(()=>{const b=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');if(!b)return false;b.scrollTop=b.scrollHeight;return b.scrollTop>0})()"))
)

# Short viewport makes both outer and Alpha inner regions genuinely scrollable.
browser$Emulation$setDeviceMetricsOverride(
  width = 900L, height = 420L, deviceScaleFactor = 1, mobile = FALSE
)
Sys.sleep(0.3)
check(
  "outer sidebar genuinely overflows",
  isTRUE(evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');return !!o&&o.scrollHeight>o.clientHeight+1})()"))
)
evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');o.scrollTop=0;a.scrollTop=0;return true})()")
gutter_point <- evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const r=document.querySelector('[data-slot=aui_thread-list-root]');const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');const or=o.getBoundingClientRect(),rr=r.getBoundingClientRect(),ar=a.getBoundingClientRect();return {x:rr.right+6,y:Math.max(or.top+12,Math.min(ar.top+40,or.bottom-12))}})()")
browser$Input$dispatchMouseEvent(
  type = "mouseWheel", x = gutter_point$x, y = gutter_point$y,
  deltaX = 0, deltaY = 180
)
Sys.sleep(0.3)
check(
  "dedicated right gutter wheels the outer sidebar only",
  isTRUE(evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');return o.scrollTop>0&&a.scrollTop===0})()"))
)
evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');o.scrollTop=0;a.scrollTop=0;return true})()")
inner_point <- evaluate("(()=>{const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');const r=a.getBoundingClientRect();return {x:r.left+Math.min(40,r.width/2),y:r.top+40}})()")
browser$Input$dispatchMouseEvent(
  type = "mouseWheel", x = inner_point$x, y = inner_point$y,
  deltaX = 0, deltaY = 180
)
Sys.sleep(0.3)
check(
  "project history body still wheels its inner list only",
  isTRUE(evaluate("(()=>{const o=document.querySelector('[data-slot=aui_thread-list-outer-scroll]');const a=document.querySelector('[data-project=\"/workspace/project-a\"] [data-slot=aui_workspace-project-threads]');return o.scrollTop===0&&a.scrollTop>0})()"))
)
browser$Emulation$setDeviceMetricsOverride(
  width = 1100L, height = 760L, deviceScaleFactor = 1, mobile = FALSE
)
Sys.sleep(0.3)
check(
  "collapse Alpha leaves Beta under independent user control",
  wait_for("(()=>{const a=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-a\"]');const b=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-b\"]');const ah=a?.querySelector('[data-slot=aui_workspace-project-header]');const bh=b?.querySelector('[data-slot=aui_workspace-project-header]');if(!ah||!bh)return false;if(ah.getAttribute('aria-expanded')==='true')ah.click();return ah.getAttribute('aria-expanded')==='false'&&bh.getAttribute('aria-expanded')==='true'&&!a.querySelector('[data-slot=aui_workspace-project-threads]')&&!!b.querySelector('[data-slot=aui_workspace-project-threads]')})()")
)
check(
  "reopen Alpha without changing Beta",
  wait_for("(()=>{const a=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-a\"]');const b=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-b\"]');const ah=a?.querySelector('[data-slot=aui_workspace-project-header]');const bh=b?.querySelector('[data-slot=aui_workspace-project-header]');if(!ah||!bh)return false;if(ah.getAttribute('aria-expanded')==='false')ah.click();return ah.getAttribute('aria-expanded')==='true'&&bh.getAttribute('aria-expanded')==='true'&&a.innerText.includes('Alpha session')&&a.innerText.includes('Alpha history 13')})()")
)
check(
  "Collapse all folders button is actionable",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-slot=aui_workspace-collapse-all]');if(!x)return false;x.click();return true})()"))
)
check(
  "Collapse all closes every active folder",
  wait_for("[...document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"]) [data-slot=aui_workspace-project-header]')].every(h=>h.getAttribute('aria-expanded')==='false')")
)
check(
  "Collapse all preserves Workspace project order",
  isTRUE(evaluate("JSON.stringify([...document.querySelectorAll('[data-slot=aui_workspace-project-group]:not([data-archived=\"true\"])')].map(x=>x.dataset.project))===JSON.stringify(['/workspace/project-a','/workspace/project-d','/workspace/project-b','/workspace/project-e'])"))
)
check(
  "reopen Alpha and Beta after Collapse all",
  wait_for("(()=>{for(const p of ['/workspace/project-a','/workspace/project-b']){const h=document.querySelector(`[data-project=\"${p}\"] [data-slot=aui_workspace-project-header]`);if(h?.getAttribute('aria-expanded')==='false')h.click()}return ['/workspace/project-a','/workspace/project-b'].every(p=>document.querySelector(`[data-project=\"${p}\"] [data-slot=aui_workspace-project-header]`)?.getAttribute('aria-expanded')==='true')})()")
)
check(
  "create a new chat from the Beta folder button",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-project=\"/workspace/project-b\"] [data-slot=aui_workspace-project-new]');if(!x)return false;x.click();return true})()"))
)
check(
  "Beta folder new chat switches project without loading Beta history",
  wait_for("(()=>{const wd=document.querySelector('[data-slot=aui_working_dir]')?.dataset.workingDir;const g=document.querySelector('[data-project=\"/workspace/project-b\"]');return wd==='/workspace/project-b'&&g?.querySelector('[data-slot=aui_workspace-thread-count]')?.textContent==='2'&&!document.body.innerText.includes('HISTORY[/workspace/project-b]')})()")
)
send_text("beta folder button work")
check(
  "folder-created chat routes directly to Beta",
  wait_for("document.body.innerText.includes('ROUTE[/workspace/project-b] beta folder button work')")
)
check(
  "folder-created Beta run settles before later concurrency checks",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-run-count]').length===0", 8)
)
check(
  "Beta history remains unloaded after using its folder-created chat",
  isTRUE(evaluate("!document.body.innerText.includes('HISTORY[/workspace/project-b]')"))
)

check(
  "Workspace registry is not exposed as Favorites",
  isTRUE(evaluate("document.querySelector('[data-slot=aui_projects_toggle]')?.textContent.includes('Favorites (3)')"))
)
check(
  "open naturally sorted Favorites",
  isTRUE(evaluate("(()=>{const t=document.querySelector('[data-slot=aui_projects_toggle]');if(!t)return false;if(t.getAttribute('aria-expanded')==='false')t.click();return true})()"))
)
check(
  "Favorites use case-insensitive natural name order",
  wait_for("(()=>{const p=[...document.querySelectorAll('[data-slot=aui_project_item]')].map(x=>x.dataset.project);return JSON.stringify(p)===JSON.stringify(['/favorites/item-2','/favorites/item-10','/workspace/project-b'])})()")
)
# Add a fifth folder through the same non-native working-directory input used
# outside RStudio. It joins the Workspace registry but must not become a Favorite.
check(
  "open working-directory editor for new project",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-slot=aui_working_dir_change]');if(!x)return false;x.click();return true})()"))
)
check("working-directory input available", wait_for("!!document.querySelector('[data-slot=aui_working_dir_input]')"))
evaluate("(()=>{const e=document.querySelector('[data-slot=aui_working_dir_input]');const s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;s.call(e,'/workspace/project-c');e.dispatchEvent(new Event('input',{bubbles:true}));e.focus();return true})()")
browser$Input$dispatchKeyEvent(
  type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
)
browser$Input$dispatchKeyEvent(
  type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
)
check(
  "new project C joins Workspace",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-project-group]').length===5")
)
check(
  "new project C is not auto-favorited",
  isTRUE(evaluate("(()=>{const t=document.querySelector('[data-slot=aui_projects_toggle]')?.textContent||'';const star=document.querySelector('[data-slot=aui_working_dir_save] svg');return t.includes('Favorites (3)')&&!star?.classList.contains('fill-yellow-400')})()"))
)
check(
  "new project C is visually prepended without reordering existing projects",
  wait_for("(()=>{const p=[...document.querySelectorAll('[data-slot=aui_workspace-project-group]')].map(x=>x.dataset.project);return JSON.stringify(p)===JSON.stringify(['/workspace/project-c','/workspace/project-a','/workspace/project-d','/workspace/project-b','/workspace/project-e'])})()"),
  paste0("actual=", evaluate("JSON.stringify([...document.querySelectorAll('[data-slot=aui_workspace-project-group]')].map(x=>x.dataset.project))"))
)
check(
  "explicitly favorite project C",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-slot=aui_working_dir_save]');if(!x)return false;x.click();return true})()"))
)
check(
  "project C becomes Favorite only after save",
  wait_for("(()=>{const t=document.querySelector('[data-slot=aui_projects_toggle]')?.textContent||'';const star=document.querySelector('[data-slot=aui_working_dir_save] svg');return t.includes('Favorites (4)')&&star?.classList.contains('fill-yellow-400')})()")
)
check(
  "open Favorites containing project C",
  isTRUE(evaluate("(()=>{const t=document.querySelector('[data-slot=aui_projects_toggle]');if(!t)return false;if(t.getAttribute('aria-expanded')==='false')t.click();return true})()"))
)
check(
  "project C appears in expanded Favorites",
  wait_for("[...document.querySelectorAll('[data-slot=aui_project_item]')].some(x=>x.dataset.project==='/workspace/project-c')")
)
check(
  "remove project C from Favorites",
  isTRUE(evaluate("(()=>{const item=[...document.querySelectorAll('[data-slot=aui_project_item]')].find(x=>x.dataset.project==='/workspace/project-c');const remove=item?.querySelector('[data-slot=aui_project_remove]');if(!remove)return false;remove.click();return true})()"))
)
check(
  "unfavorite keeps project C and its history in Workspace",
  wait_for("(()=>{const t=document.querySelector('[data-slot=aui_projects_toggle]')?.textContent||'';const g=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-c\"]');return t.includes('Favorites (3)')&&!!g&&g.innerText.includes('Project Gamma')})()")
)
check(
  "expand project C history",
  isTRUE(evaluate("(()=>{const g=document.querySelector('[data-slot=aui_workspace-project-group][data-project=\"/workspace/project-c\"]');const h=g?.querySelector('[data-slot=aui_workspace-project-header]');if(!h)return false;if(h.getAttribute('aria-expanded')==='false')h.click();return true})()"))
)
click_thread("Gamma session")
check(
  "new project C history restored with owning project",
  wait_for("document.body.innerText.includes('HISTORY[/workspace/project-c] restored for session-c')")
)

click_thread("Alpha session")
check(
  "Alpha history restored with project",
  wait_for("document.body.innerText.includes('HISTORY[/workspace/project-a] restored for session-a')")
)
send_text("alpha concurrent work")
click_thread("Beta session")
check(
  "Beta history restored with project",
  wait_for("document.body.innerText.includes('HISTORY[/workspace/project-b] restored for session-b')")
)
check(
  "switching an existing project keeps Workspace order stable",
  wait_for("(()=>{const p=[...document.querySelectorAll('[data-slot=aui_workspace-project-group]')].map(x=>x.dataset.project);return JSON.stringify(p)===JSON.stringify(['/workspace/project-c','/workspace/project-a','/workspace/project-d','/workspace/project-b','/workspace/project-e'])})()")
)
send_text("beta concurrent work")

check(
  "both projects show active runs",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-run-count]').length===2", 5)
)
check(
  "background Tasks visible for both projects",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-task-count]').length===2", 5)
)
check(
  "Beta submission routed to Beta project",
  wait_for("document.body.innerText.includes('ROUTE[/workspace/project-b] beta concurrent work')")
)
click_thread("Alpha session")
check(
  "Alpha submission routed to Alpha project",
  wait_for("document.body.innerText.includes('ROUTE[/workspace/project-a] alpha concurrent work')")
)
check(
  "concurrent runs settle independently",
  wait_for("document.querySelectorAll('[data-slot=aui_workspace-run-count]').length===0", 8)
)

browser$Emulation$setDeviceMetricsOverride(
  width = 520L, height = 700L, deviceScaleFactor = 1, mobile = FALSE
)
Sys.sleep(0.4)
check(
  "narrow project labels remain bounded",
  isTRUE(evaluate("(()=>{const labels=[...document.querySelectorAll('[data-slot=aui_workspace-project-label]')];return labels.length===5&&labels.every(x=>{const r=x.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth})})()"))
)
check(
  "collapse sidebar on narrow viewport",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-slot=aui_sidebar_toggle]');if(!x)return false;x.click();return true})()"))
)
check("sidebar removed after collapse", wait_for("!document.querySelector('[data-slot=aui_thread_sidebar]')"))
check(
  "narrow composer remains visible and usable",
  isTRUE(evaluate("(()=>{const x=document.querySelector('[data-slot=aui_composer-shell]');const input=document.querySelector('[contenteditable=true]');if(!x||!input)return false;const r=x.getBoundingClientRect();return r.width>200&&r.left>=0&&r.right<=innerWidth&&r.bottom<=innerHeight})()"))
)

check(
  "zero console/runtime errors",
  length(browser_errors) == 0L,
  if (length(browser_errors)) paste(unique(browser_errors), collapse = " | ") else "0 errors"
)
logs <- if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE) else character()
check(
  "Home installed package used",
  any(grepl(paste0("installed=", home_library, "/shinyAssistantUI"), logs, fixed = TRUE)),
  paste(logs, collapse = " | ")
)
cat("CLAUDE_WORKSPACE_BROWSER_DONE\n")
