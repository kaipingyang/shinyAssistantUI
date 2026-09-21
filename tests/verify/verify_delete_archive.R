suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-lifecycle-out-"), tempfile("aui-lifecycle-err-"))
  browser <- NULL
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    shiny::runApp("tests/verify/delete_archive_app.R",
                 host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  for (i in seq_len(100L)) {
    if (!app$is_alive()) stop(paste(readLines(logs[[2L]], warn = FALSE), collapse = "\n"))
    if (file.exists(logs[[2L]]) &&
        any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
    Sys.sleep(0.1)
  }

  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
    "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload"
  )))
  browser <- ChromoteSession$new(width = 1000, height = 800)
  console_errors <- character()
  current_stage <- "boot"
  browser$Runtime$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) {
      console_errors <<- c(console_errors, paste(current_stage, paste(vapply(event$args, function(arg) {
        as.character(arg$value %||% arg$description %||% "")
      }, character(1)), collapse = " ")))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    console_errors <<- c(console_errors, paste(
      current_stage, event$exceptionDetails$exception$description %||% event$exceptionDetails$text
    ))
  })
  value <- function(script) {
    result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_for <- function(script, timeout = 8) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(script))) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.05)
    }
  }
  check <- function(name, condition) {
    cat(sprintf("[%s] %s\n", if (isTRUE(condition)) "PASS" else "FAIL", name))
    if (!isTRUE(condition)) {
      stop(current_stage, ": ", name, "\n", paste(console_errors, collapse = "\n"))
    }
  }
  js_string <- function(text) as.character(toJSON(text, auto_unbox = TRUE))
  key <- function(name, code, vk, modifiers = 0L) {
    for (type in c("keyDown", "keyUp")) {
      browser$Input$dispatchKeyEvent(
        type = type, key = name, code = code,
        windowsVirtualKeyCode = as.integer(vk), modifiers = as.integer(modifiers)
      )
    }
  }
  in_view <- function(expression) {
    paste0("(()=>{const e=", expression,
           ";if(!e)return false;const r=e.getBoundingClientRect();",
           "return r.width>0&&r.height>0&&r.left>=0&&r.top>=0&&",
           "r.right<=innerWidth+1&&r.bottom<=innerHeight+1})()")
  }
  element <- function(selector) paste0("document.querySelector(", js_string(selector), ")")
  click <- function(expression) {
    check("click target is inside viewport", wait_for(in_view(expression)))
    point <- fromJSON(value(paste0(
      "(()=>{const r=(", expression, ").getBoundingClientRect();",
      "return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()"
    )))
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    for (type in c("mousePressed", "mouseReleased")) {
      browser$Input$dispatchMouseEvent(
        type = type, x = point$x, y = point$y, button = "left", clickCount = 1L
      )
    }
  }
  item <- function(title) paste0(
    "[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>",
    "e.querySelector('[data-slot=aui_thread-list-item-title]')?.textContent.trim()===",
    js_string(title), ")"
  )
  open_menu <- function(title) {
    click(paste0("(", item(title), ")?.querySelector('[data-slot=aui_thread-list-item-more]')"))
    check("session menu is inside viewport", wait_for(in_view(
      element("[data-slot=aui_thread-list-item-more-content]")
    )))
  }
  menu_action <- function(label) click(paste0(
    "[...document.querySelectorAll('[data-slot=aui_thread-list-item-more-item]')]",
    ".find(e=>e.textContent.trim()===", js_string(label), ")"
  ))
  open_history <- function(title, id) {
    click(paste0("(", item(title), ")?.querySelector('[data-slot=aui_thread-list-item-trigger]')"))
    check(paste("history restores", id), wait_for(paste0(
      "document.body.innerText.includes(", js_string(paste0("RESTORED[", id, "]")), ")"
    )))
  }
  navigate <- function() {
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
    browser$Page$loadEventFired()
    check("installed widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))
  }

  navigate()
  check("synthetic sessions listed", wait_for(paste0("!!(", item("sess-del"), ")")))
  current_stage <- "highlight"
  click(element(".aui-lexical-input[contenteditable=true]"))
  browser$Input$insertText(text = "show code")
  key("Enter", "Enter", 13L)
  check("assistant R code is syntax-highlighted", wait_for(
    "!!document.querySelector('[data-syntax-highlighter=prism] code span')"
  ))

  current_stage <- "sidebar-reload"
  click(element("[data-slot=aui_sidebar_toggle]"))
  check("sidebar collapses", wait_for("!document.querySelector('[data-slot=aui_thread_sidebar]')"))
  navigate()
  check("sidebar defaults to expanded after reload", wait_for(
    "document.querySelector('[data-slot=aui_thread_sidebar]')?.getAttribute('data-collapsed')==='false'"
  ))

  current_stage <- "rename"
  open_history("sess-keep", "sess-keep")
  open_menu("sess-keep")
  menu_action("Rename")
  check("rename editor opens", wait_for("!!document.querySelector('.aui-thread-rename-input')"))
  key("a", "KeyA", 65L, 2L)
  browser$Input$insertText(text = "Discarded title")
  key("Escape", "Escape", 27L)
  check("Escape keeps the original title", wait_for(paste0(
    "!document.querySelector('.aui-thread-rename-input')&&!!(", item("sess-keep"), ")"
  )))
  check("Escape does not invoke backend rename",
        isTRUE(value("document.getElementById('renamed-probe').textContent===''")))
  open_menu("sess-keep")
  menu_action("Rename")
  check("rename editor reopens", wait_for("!!document.querySelector('.aui-thread-rename-input')"))
  key("a", "KeyA", 65L, 2L)
  browser$Input$insertText(text = "Renamed keep")
  key("Enter", "Enter", 13L)
  check("Enter updates title and invokes backend rename", wait_for(paste0(
    "!!(", item("Renamed keep"),
    ")&&document.getElementById('renamed-probe').textContent==='sess-keep|Renamed keep'"
  )))
  navigate()
  check("renamed title survives reload", wait_for(paste0("!!(", item("Renamed keep"), ")")))
  open_history("Renamed keep", "sess-keep")

  current_stage <- "archive"
  open_menu("sess-arch")
  menu_action("Archive")
  archived <- "document.querySelector('[data-slot=aui_thread-list-archived]')?.textContent.includes('sess-arch')"
  check("archive moves session out of the active list", wait_for(paste0(
    archived, "&&!(", item("sess-arch"), ")"
  )))
  navigate()
  check("archive survives reload", wait_for(paste0(archived, "&&!(", item("sess-arch"), ")")))
  click(element("[data-slot=aui_thread-list-unarchive]"))
  check("unarchive returns session to active list", wait_for(paste0("!!(", item("sess-arch"), ")")))
  open_history("sess-arch", "sess-arch")

  current_stage <- "delete"
  open_history("sess-del", "sess-del")
  open_menu("sess-del")
  menu_action("Delete")
  check("delete confirmation is inside viewport", wait_for(in_view(
    element("[data-slot=aui_delete_confirm]")
  )))
  check("opening confirmation does not delete",
        isTRUE(value("document.getElementById('deleted-probe').textContent===''")))
  click(element("[data-cancel-delete]"))
  check("Cancel dismisses dialog and keeps session", wait_for(paste0(
    "!document.querySelector('[data-slot=aui_delete_confirm]')&&!!(", item("sess-del"), ")"
  )))
  check("Cancel does not invoke backend delete",
        isTRUE(value("document.getElementById('deleted-probe').textContent===''")))
  open_menu("sess-del")
  menu_action("Delete")
  click(element("[data-confirm-delete]"))
  check("confirmed delete dismisses dialog", wait_for(
    "!document.querySelector('[data-slot=aui_delete_confirm]')"
  ))
  check("confirmed delete invokes the correct backend callback", wait_for(
    "document.getElementById('deleted-probe').textContent==='sess-del'"
  ))
  check("deleted session leaves active list", wait_for(paste0("!(", item("sess-del"), ")")))
  navigate()
  check("deleted session stays absent while other sessions survive", wait_for(paste0(
    "!(", item("sess-del"), ")&&!!(", item("Renamed keep"), ")&&!!(", item("sess-arch"), ")"
  )))
  open_history("Renamed keep", "sess-keep")
  check("no browser console errors or exceptions", length(console_errors) == 0L)
  cleanup()
  cat("DELETE_ARCHIVE_CHROMIUM_DONE\n")
}

main()
