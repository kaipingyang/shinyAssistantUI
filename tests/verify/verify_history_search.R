suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  source("tests/verify/window_error_capture.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".")
  port <- httpuv::randomPort()
  logs <- c(tempfile("history-search-out-"), tempfile("history-search-err-"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    library(shinyAssistantUI)
    installed <- normalizePath(find.package("shinyAssistantUI"))
    stopifnot(startsWith(installed, paste0(normalizePath(path.expand("~")), "/")))
    message("INSTALL=", installed, " VERSION=", packageVersion("shinyAssistantUI"))
    shiny::runApp("tests/verify/history_search_app.R", host = "127.0.0.1",
                  port = port, launch.browser = FALSE)
  }, args = list(project = project, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
  ready <- FALSE
  for (i in seq_len(150L)) {
    if (!app$is_alive()) break
    ready <- any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE), fixed = TRUE))
    if (ready) break
    Sys.sleep(0.1)
  }
  if (!ready) stop(paste(readLines(logs[[2L]], warn = FALSE), collapse = "\n"))
  cat(grep("INSTALL=", readLines(logs[[2L]], warn = FALSE), value = TRUE), "\n")

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter"
  )))
  # Keep Page enabled so one-shot load waits cannot discard preload error capture.
  browser <- ChromoteSession$new(width = 1550, height = 950, auto_events = FALSE)
  browser$Emulation$setDeviceMetricsOverride(
    width = 1550L, height = 950L, deviceScaleFactor = 1, mobile = FALSE
  )
  stage <- "boot"
  errors <- network_errors <- character()
  browser$Runtime$enable()
  browser$Network$enable()
  window_errors <- capture_browser_window_errors(browser, function() stage)
  probe_js <- paste(readLines("tests/verify/history_search_probe.js", warn = FALSE), collapse = "\n")
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- c(errors, paste(stage, paste(
      vapply(event$args, function(arg) as.character(arg$value %||% arg$description %||% ""), character(1)),
      collapse = " "
    )))
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, paste(stage,
      event$exceptionDetails$exception$description %||% event$exceptionDetails$text))
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    network_errors <<- c(network_errors, paste(stage, event$errorText))
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- c(network_errors, event$response$url)
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) {
      cat("EVALUATION_FAILED ", js, "\n", toJSON(result$exceptionDetails, auto_unbox = TRUE), "\n", sep = "")
      cat("BROWSER_ERRORS ", paste(errors, collapse = "\n"), "\n", sep = "")
      detail <- browser$Runtime$evaluate(
        "JSON.stringify({body:document.body.innerText.slice(-2500),trace:window.__auiSearchDialogTrace})",
        returnByValue = TRUE
      )
      cat("FAILURE_DOM ", detail$result$value, "\n", sep = "")
      stop(result$exceptionDetails$text)
    }
    result$result$value
  }
  wait_for <- function(js, timeout = 12) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(js))) return(TRUE)
      if (!app$is_alive() || Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.03)
    }
  }
  checks <- 0L
  check <- function(name, ok) {
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", name))
    checks <<- checks + 1L
    if (!isTRUE(ok)) {
      cat("DOM ", value("document.body.innerText.slice(-1600)"), "\n", sep = "")
      cat("SEARCH_STATE ", value(
        "JSON.stringify({chat:document.getElementById('chat')?.innerText.slice(0,1600),probe:document.getElementById('search-probe')?.textContent,trace:window.__auiSearchDialogTrace,sent:window.__auiSearchSent?.slice(-12)})"
      ), "\n", sep = "")
      cat(c(errors, network_errors, tail(readLines(logs[[2L]], warn = FALSE), 12)), sep = "\n")
      stop(stage, ": ", name)
    }
  }
  js <- function(x) as.character(toJSON(x, auto_unbox = TRUE))
  element <- function(selector) paste0("document.querySelector(", js(selector), ")")
  key <- function(name, code, vk, modifiers = 0L) {
    for (type in c("keyDown", "keyUp")) browser$Input$dispatchKeyEvent(
      type = type, key = name, code = code,
      windowsVirtualKeyCode = as.integer(vk), modifiers = as.integer(modifiers)
    )
  }
  click <- function(selector) {
    expr <- element(selector)
    check(paste("visible click target", selector), wait_for(paste0(
      "(()=>{const e=", expr, ";if(!e)return false;e.scrollIntoView({block:'nearest',behavior:'instant'});",
      "const r=e.getBoundingClientRect(),hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);",
      "return r.width>0&&r.height>0&&r.x>=0&&r.y>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1&&e.contains(hit)})()"
    )))
    point <- value(paste0(
      "(()=>{const r=", expr, ".getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()"
    ))
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    for (type in c("mousePressed", "mouseReleased")) browser$Input$dispatchMouseEvent(
      type = type, x = point$x, y = point$y, button = "left", clickCount = 1L
    )
  }
  rows <- function(id = "chat", archived = FALSE) paste0(
    "document.querySelectorAll(", js(paste0("#", id, " [data-slot=aui_thread-list-",
      if (archived) "archived-item" else "item", "]")), ")"
  )
  row <- function(id, widget = "chat", archived = FALSE) paste0(
    "#", widget, " [data-slot=aui_thread-list-",
    if (archived) "archived-item" else "item", "][data-thread-id='", id, "']"
  )
  search <- function(text, id = "chat") {
    selector <- paste0("#", id, " input[aria-label='Search history']")
    click(selector)
    before <- value("window.__auiSearchTimings.length")
    key("a", "KeyA", 65L, 2L)
    browser$Input$insertText(text = text)
    check(paste(id, "settles query", text), wait_for(paste0(
      "window.__auiSearchTimings.length>", before,
      "&&window.__auiSearchTimings.at(-1).settled"
    )))
  }
  clear <- function(id = "chat") {
    click(paste0("#", id, " input[aria-label='Search history']"))
    key("Escape", "Escape", 27L)
    check(paste(id, "Escape clears without moving focus"), wait_for(paste0(
      element(paste0("#", id, " input[aria-label='Search history']")), ".value===''&&",
      "document.activeElement===", element(paste0("#", id, " input[aria-label='Search history']")), "&&",
      element(paste0("#", id, " [data-slot=aui_thread-list-outer-scroll]")), ".dataset.searchQuery===''"
    )))
  }
  navigate <- function(query = "", archived_count = 1L) {
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/%s", port, query))
    browser$Page$loadEventFired()
    check("two installed searchable sidebars mount", wait_for(
      "document.querySelectorAll('input[aria-label=\"Search history\"]').length===2"
    ))
    check("large catalogs arrive with a bounded first page", wait_for(paste0(
      rows(), ".length===100&&", rows(archived = TRUE), ".length===", archived_count, "&&",
      rows("workspace"), ".length===100"
    )))
    check("direct window-error capture is active", isTRUE(value("window.__auiWindowErrorProbeReady===true")))
    value(probe_js)
    value("window.__auiSearchInstallSpy();true")
  }
  open_menu <- function(id) {
    click(paste0(row(id), " [data-slot=aui_thread-list-item-more]"))
    check("result menu is within the viewport", wait_for(
      "(()=>{const e=document.querySelector('[data-slot=aui_thread-list-item-more-content]');if(!e)return false;const r=e.getBoundingClientRect();return r.x>=0&&r.y>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()"
    ))
  }
  menu_item <- function(text) {
    value(paste0(
      "[...document.querySelectorAll('[data-slot=aui_thread-list-item-more-item]')].find(e=>e.textContent.trim()===",
      js(text), ")?.setAttribute('data-search-action','selected');true"
    ))
    click("[data-search-action=selected]")
  }

  navigate()
  stage <- "catalog-search";
  search("History target [a.*] \u4e2d\u6587")
  check("literal Chinese/title result beyond record 100 is found", isTRUE(value(paste0(
    rows(), ".length===1&&!!", element(row("history-2000"))
  ))))
  check("typing does not load history or emit backend input", isTRUE(value(
    "window.__auiSearchSent.length===0"
  )))
  key("Enter", "Enter", 13L)
  check("Enter in search does not submit or navigate", isTRUE(value(
    "window.__auiSearchSent.length===0"
  )))
  check("other widget query is independent", isTRUE(value(
    "document.querySelector('#workspace input[aria-label=\"Search history\"]').value===''"
  )))
  click(paste0(row("history-2000"), " [data-slot=aui_thread-list-item-trigger]"))
  check("deep result loads the correct original session and historical tool", wait_for(
    "document.getElementById('chat').innerText.includes('RESTORED[history-2000]')&&document.getElementById('chat').innerText.includes('Read')"
  ))
  check("selected result remains active", isTRUE(value(paste0(
    element(row("history-2000")), ".hasAttribute('data-active')"
  ))))
  search("Needle-preview")
  check("existing preview matches active and archived metadata", isTRUE(value(paste0(
    "!!", element(row("history-1999")), "&&!!", element(row("archived-target", archived = TRUE)),
    "&&", rows(), ".length===1"
  ))))
  check("filtering does not replace the current conversation", isTRUE(value(
    "document.getElementById('chat').innerText.includes('RESTORED[history-2000]')"
  )))
  click(paste0(row("archived-target", archived = TRUE), " [data-slot=aui_thread-list-unarchive]"))
  check("restore preserves search and moves the correct old session", wait_for(paste0(
    "!!", element(row("archived-target")), "&&! ", element(row("archived-target", archived = TRUE)),
    "&&document.getElementById('search-probe').textContent.includes('chat|archived-target|FALSE')"
  )))
  search("no-such-conversation")
  check("no-result feedback is visible", isTRUE(value(
    "document.querySelector('#chat [data-slot=aui_thread-list-empty]')?.textContent.includes('No matching conversations.')"
  )))
  clear()
  click("#chat [aria-label='Show more conversations']")
  check("Show more grows only the rendered page", wait_for(paste0(rows(), ".length===200")))

  stage <- "workspace-search"
  before_groups <- value(
    "[...document.querySelectorAll('#workspace [data-slot=aui_workspace-project-group]')].map(e=>({project:e.dataset.project,archived:e.dataset.archived,expanded:e.dataset.expanded}))"
  )
  search("History target [a.*] \u4e2d\u6587", "workspace")
  check("search reveals a match in a previously closed folder", isTRUE(value(paste0(
    "!!", element(row("history-2000", "workspace")),
    "&&", element(row("history-2000", "workspace")), ".closest('[data-slot=aui_workspace-project-group]').dataset.expanded==='true'"
  ))))
  clear("workspace")
  check("clearing restores exact folder expansion choices", identical(
    value("[...document.querySelectorAll('#workspace [data-slot=aui_workspace-project-group]')].map(e=>({project:e.dataset.project,archived:e.dataset.archived,expanded:e.dataset.expanded}))"),
    before_groups
  ))

  stage <- "search-actions"
  value(
    "window.__auiSearchDialogTrace=[];new MutationObserver(()=>{const root=document.getElementById('chat'),entry={dialog:!!document.querySelector('[data-slot=aui_delete_confirm]'),cancel:!!document.querySelector('[data-cancel-delete]'),target:[...root.querySelectorAll('[data-thread-id=\"history-2000\"]')].map(e=>e.dataset.slot),probe:document.getElementById('search-probe').textContent};const key=JSON.stringify(entry),previous=window.__auiSearchDialogTrace.at(-1);if(previous?.key!==key)window.__auiSearchDialogTrace.push({key,time:performance.now()});}).observe(document.body,{childList:true,subtree:true});true"
  )
  search("History target")
  open_menu("history-2000")
  menu_item("Rename")
  check("search result opens its rename editor", wait_for("!!document.querySelector('.aui-thread-rename-input')"))
  key("a", "KeyA", 65L, 2L)
  browser$Input$insertText(text = "Renamed historical target")
  key("Enter", "Enter", 13L)
  check("rename updates the backend and filtered result", wait_for(
    "document.getElementById('search-probe').textContent.includes('Renamed historical target')&&document.querySelector('#chat [data-slot=aui_thread-list-empty]')!==null"
  ))
  search("Renamed historical")
  check("renamed history remains searchable", isTRUE(value(paste0("!!", element(row("history-2000"))))))
  open_menu("history-2000")
  menu_item("Archive")
  check("archive retains the matching result in the archived section", wait_for(paste0(
    "!!", element(row("history-2000", archived = TRUE)), "&&! ", element(row("history-2000")),
    "&&document.getElementById('search-probe').textContent.includes('chat|history-2000|TRUE')"
  )))
  click(paste0(row("history-2000", archived = TRUE), " [data-slot=aui_thread-list-unarchive]"))
  check("restored renamed result returns to active results after backend confirmation", wait_for(paste0(
    "!!", element(row("history-2000")),
    "&&document.getElementById('search-probe').textContent.includes('chat|history-2000|FALSE')"
  )))
  open_menu("history-2000")
  menu_item("Delete")
  check("delete still requires explicit confirmation", wait_for("!!document.querySelector('[data-slot=aui_delete_confirm]')"))
  click("[data-cancel-delete]")
  check("cancel keeps the filtered session", wait_for(paste0(
    "!document.querySelector('[data-slot=aui_delete_confirm]')&&!!", element(row("history-2000"))
  )))
  open_menu("history-2000")
  menu_item("Delete")
  click("[data-confirm-delete]")
  check("confirmed deletion removes only the matching session", wait_for(paste0(
    "!", element(row("history-2000")), "&&document.getElementById('search-probe').textContent.includes('chat|history-2000')"
  )))
  search("unmatched-new-chat")
  click("#chat [data-slot=aui_thread-list-new]")
  check("New Thread resets the filter", wait_for(
    "document.querySelector('#chat input[aria-label=\"Search history\"]').value===''"
  ))
  click("#chat .aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "Search fixture prompt")
  key("Enter", "Enter", 13L)
  check("real composer starts streaming", wait_for(
    "document.getElementById('chat').innerText.includes('SEARCH_FIXTURE_STREAM_START')"
  ))
  search("History 001")
  check("sidebar filtering does not interrupt the active stream", wait_for(
    "document.getElementById('chat').innerText.includes('SEARCH_FIXTURE_STREAM_DONE')"
  ))
  navigate(archived_count = 0L)
  search("History 1998")
  click(paste0(row("history-1998"), " [data-slot=aui_thread-list-item-trigger]"))
  check("history is restored again after full browser reload", wait_for(
    "document.getElementById('chat').innerText.includes('RESTORED[history-1998]')"
  ))

  evidence <- list()
  for (rep in seq_len(3L)) {
    arms <- if (rep %% 2L) c(0L, 1L) else c(1L, 0L)
    for (previews in arms) {
      stage <- paste("benchmark", rep, previews)
      navigate(sprintf("?mode=benchmark&previews=%d&rep=%d", previews, rep))
      for (term in c("H", "History", "History 0", "History 019", "History target", "absent", "History 1998")) {
        search(term)
      }
      samples <- value("window.__auiSearchTimings")
      times <- vapply(samples, `[[`, numeric(1), "elapsedMs")
      item <- list(
        repetition = rep, previews = previews == 1L, sessions = 2001L,
        samples = samples, medianMs = unname(median(times)),
        p95Ms = unname(quantile(times, 0.95)), maxMs = max(times),
        backendInputs = length(value("window.__auiSearchSent"))
      )
      evidence[[length(evidence) + 1L]] <- item
      cat("SEARCH_PERFORMANCE ", toJSON(item, auto_unbox = TRUE, digits = 4), "\n", sep = "")
      if (previews == 1L) {
        check("every delivered title/preview result paints within 250 ms", all(times < 250))
      }
      check("search never sends backend input", item$backendInputs == 0L)
      check("broad queries keep at most 101 rendered rows", all(vapply(samples, `[[`, numeric(1), "rows") <= 101L))
    }
  }
  title_times <- unlist(lapply(Filter(function(item) !item$previews, evidence),
    function(item) vapply(item$samples, `[[`, numeric(1), "elapsedMs")))
  preview_times <- unlist(lapply(Filter(function(item) item$previews, evidence),
    function(item) vapply(item$samples, `[[`, numeric(1), "elapsedMs")))
  comparison <- list(
    titleMedianMs = unname(median(title_times)),
    previewMedianMs = unname(median(preview_times)),
    titleP95Ms = unname(quantile(title_times, 0.95)),
    previewP95Ms = unname(quantile(preview_times, 0.95)),
    titleMaxMs = max(title_times),
    previewMaxMs = max(preview_times)
  )
  cat("SEARCH_COMPARISON ", toJSON(comparison, auto_unbox = TRUE, digits = 4), "\n", sep = "")
  check("preview adds less than one frame of median input latency",
        comparison$previewMedianMs - comparison$titleMedianMs < 16.7)
  check("preview p95 overhead remains below 30 ms",
        comparison$previewP95Ms - comparison$titleP95Ms < 30)
  check("zero browser console errors or exceptions", length(errors) == 0L)
  check("zero direct window errors", length(window_errors()) == 0L)
  check("zero network or HTTP failures", length(network_errors) == 0L)
  cat("HISTORY_SEARCH_EVIDENCE ", toJSON(evidence, auto_unbox = TRUE, digits = 4), "\n", sep = "")
  cleanup()
  cat("HISTORY_SEARCH_VERIFY_DONE checks=", checks, "\n", sep = "")
}
main()
