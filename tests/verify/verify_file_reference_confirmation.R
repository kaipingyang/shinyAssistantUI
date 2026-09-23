suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".")
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  root <- tempfile("confirmed-file-fixture-")
  dir.create(root, mode = "0700")
  root <- normalizePath(root)
  home <- file.path(root, "home")
  dir.create(home)
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  stdout <- file.path(root, "app.out")
  stderr <- file.path(root, "app.err")
  read_log <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
  port <- httpuv::randomPort()
  app <- callr::r_bg(function(home_lib, root, port) {
    .libPaths(c(home_lib, .libPaths()))
    library(shiny)
    library(shinyAssistantUI, lib.loc = home_lib)
    library(jsonlite)
    stopifnot(identical(normalizePath(find.package("shinyAssistantUI")),
                        file.path(home_lib, "shinyAssistantUI")))
    cat("INSTALLED_VERSION=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
    main_project <- file.path(root, "project")
    other_project <- file.path(root, "other")
    for (directory in c(file.path(main_project, c("src", "a", "b")),
                        other_project, file.path(path.expand("~"), ".config", "example"))) {
      dir.create(directory, recursive = TRUE)
    }
    targets <- c(
      file.path(main_project, c("exists.R", "gone.R", "slow.R", "src/known.R", "src/nested.R", "a/dm.R", "b/dm.R")),
      file.path(other_project, "exists.R"),
      file.path(path.expand("~"), ".config", "example", c("prefs.json", "settings.json"))
    )
    stopifnot(all(file.create(targets)))
    state <- reactiveVal(list(opened = list(), checked = list(), sent = list(), loads = list(), openRequests = list()))
    record <- function(field, value) {
      next_state <- isolate(state())
      next_state[[field]] <- append(next_state[[field]], list(value))
      state(next_state)
    }
    testthat::local_mocked_bindings(
      getSourceEditorContext = function() {
        opened <- isolate(state())$opened
        list(path = if (length(opened)) tail(opened, 1L)[[1L]]$path else "")
      },
      navigateToFile = function(file, line, ...) {
        record("opened", list(path = file, line = line, checkedCount = length(isolate(state())$checked)))
        invisible(NULL)
      },
      .package = "rstudioapi"
    )
    peek <- function() lapply(c("src/nested.R", "a/dm.R", "b/dm.R"),
                             function(path) list(kind = "file", path = path))
    text <- paste0(
      "No known path: `settings.json`. Missing: `missing.R`. Ambiguous: `dm.R`.\n\n",
      "Existing: `exists.R:7`. Same file: `exists.R:9`. Structured: `known.R:11`.\n\n",
      "Warm index: `nested.R`. Explicit home: `~/.config/example/prefs.json:13`.\n\n",
      "May disappear: `gone.R`. Deferred editor: `slow.R`."
    )
    history <- list(
      list(id = "history-user", role = "user", content = list(list(type = "text", text = "File history"))),
      list(id = "history-text", role = "assistant",
           content = list(list(type = "text", text = paste(text, "HISTORY_FILES_READY")))),
      list(id = "history-bash", role = "assistant", content = list(list(
        type = "tool-call", toolCallId = "history-bash", toolName = "Bash",
        args = list(command = "ls -l ~/.config/example/settings.json"),
        argsText = as.character(toJSON(list(command = "ls -l ~/.config/example/settings.json"), auto_unbox = TRUE)),
        result = "Synthetic listing only", isError = FALSE
      ))),
      list(id = "history-read", role = "assistant", content = list(list(
        type = "tool-call", toolCallId = "history-read", toolName = "Read",
        args = list(file_path = file.path(main_project, "src/known.R")),
        argsText = as.character(toJSON(list(file_path = file.path(main_project, "src/known.R")), auto_unbox = TRUE)),
        result = "Synthetic historical result", isError = FALSE
      )))
    )
    ui <- bslib::page_fluid(
      tags$head(tags$link(rel = "icon", href = "data:,")),
      actionButton("remove_file", "Remove fixture file"),
      actionButton("finish_open", "Complete synthetic navigation"),
      bslib::layout_columns(
        col_widths = c(8, 4),
        assistantUIOutput("chat", height = "86vh"),
        div(assistantUIOutput("other", height = "41vh"), assistantUIOutput("plain", height = "41vh"))
      ),
      div(style = "display:none", textOutput("file_probe"))
    )
    server <- function(input, output, session) {
      recheck_remaining <- 0L
      recheck_revision <- 0L
      pending_open <- NULL
      output$file_probe <- renderText(as.character(toJSON(state(), auto_unbox = TRUE, null = "null")))
      outputOptions(output, "file_probe", suspendWhenHidden = FALSE)
      observeEvent(input$remove_file, unlink(file.path(main_project, "gone.R")), ignoreInit = TRUE)
      observeEvent(input$recheck_on_press, {
        recheck_remaining <<- length(unique(unlist(isolate(input$chat_input_resolve_files$paths))))
        recheck_revision <<- recheck_revision + 1L
        session$sendCustomMessage("chat_input:proactive-messages", list(
          version = 1L, operation = "replace", threadId = "file-history",
          revision = recheck_revision, messages = history
        ))
      }, ignoreInit = TRUE)
      observeEvent(input$finish_open, {
        pending <- pending_open
        pending_open <<- NULL
        if (!is.null(pending)) {
          pending$resolve(shinyAssistantUI:::.addin_open_file(
            pending$path, pending$line, main_project, peek
          ))
        }
      }, ignoreInit = TRUE)
      handler <- function(message, on_chunk, on_done, thread_id, ...) {
        record("sent", list(text = message, thread = thread_id))
        on_chunk("Live: `exists.R:17`, unresolved `settings.json`. LIVE_FILES_READY")
        on_done()
      }
      controls <- assistantUIServer(
        "chat", handler, persistence = "server", show_thread_list = TRUE,
        workspace_mode = TRUE, working_dir = main_project,
        file_reference_resolver = function(path, thread_id, project = NULL) {
          if (recheck_remaining > 0L) {
            Sys.sleep(0.02)
            recheck_remaining <<- recheck_remaining - 1L
          }
          record("checked", list(
            path = path, thread = thread_id, project = project,
            request = isolate(input$chat_input_resolve_files$requestId)
          ))
          shinyAssistantUI:::.addin_resolve_file_path(path, main_project, peek)
        },
        on_open_file = function(path, line = NULL, ...) {
          record("openRequests", list(path = path, line = line))
          if (basename(path) == "slow.R") {
            return(promises::promise(function(resolve, reject) {
              pending_open <<- list(path = path, line = line, resolve = resolve)
            }))
          }
          shinyAssistantUI:::.addin_open_file(path, line, main_project, peek)
        },
        on_session_load = function(session_id, thread_id, send_thread, ...) {
          record("loads", list(session = session_id, thread = thread_id))
          send_thread(history)
        }
      )
      assistantUIServer(
        "other", handler, persistence = "none", working_dir = other_project,
        on_open_file = function(path, line = NULL, ...) {
          shinyAssistantUI:::.addin_open_file(path, line, other_project)
        }
      )
      assistantUIServer("plain", handler, persistence = "none")
      session$onFlushed(function() {
        controls$send_sessions(list(sessions = list(list(
          id = "file-history", title = "Confirmed file history", project = main_project
        ))))
      }, once = TRUE)
    }
    shiny::runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(home_lib = home_lib, root = root, port = port),
  stdout = stdout, stderr = stderr, supervise = TRUE, env = c(HOME = home, R_LIBS_USER = home_lib))

  wait_until <- function(predicate, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(predicate())) return(TRUE)
      if (!app$is_alive() || Sys.time() > deadline) return(FALSE)
      Sys.sleep(0.05)
    }
  }
  if (!wait_until(function() any(grepl("Listening on", read_log(stderr), fixed = TRUE)), 25)) {
    stop(paste(c(read_log(stdout), read_log(stderr)), collapse = "\n"), call. = FALSE)
  }
  cat(grep("INSTALLED_VERSION=", read_log(stdout), value = TRUE), "\n")
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- ChromoteSession$new(width = 1440, height = 1050)
  errors <- exceptions <- network <- character()
  stage <- "mount"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- c(errors, "console error")
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    exceptions <<- c(exceptions, event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network <<- c(network, event$errorText)
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network <<- c(network, "HTTP error")
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
    result$result$value
  }
  wait_js <- function(js, timeout = 15) wait_until(function() isTRUE(value(js)), timeout)
  quoted <- function(text) as.character(toJSON(text, auto_unbox = TRUE))
  checks <- 0L
  check <- function(label, ok) {
    stage <<- label
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", label))
    if (!isTRUE(ok)) {
      cat("FILE_PROBE ", value("document.getElementById('file_probe').textContent"), "\n")
      cat("DOM ", value("document.body.innerText.slice(-1800)"), "\n")
      cat(paste(tail(read_log(stderr), 15L), collapse = "\n"), "\n")
      stop(label, call. = FALSE)
    }
    checks <<- checks + 1L
  }
  click <- function(selector) {
    stopifnot(wait_js(paste0("!!document.querySelector(", quoted(selector), ")")))
    value(paste0("document.querySelector(", quoted(selector), ").scrollIntoView({block:'center',behavior:'instant'});true"))
    Sys.sleep(0.1)
    point <- value(paste0(
      "(()=>{const e=document.querySelector(", quoted(selector), "),r=e.getBoundingClientRect();",
      "const x=r.x+r.width/2,y=r.y+r.height/2;",
      "return {x,y,visible:r.width>0&&r.height>0&&x>=0&&y>=0&&x<innerWidth&&y<innerHeight&&e.contains(document.elementFromPoint(x,y))}})()"
    ))
    if (!isTRUE(point$visible)) stop("Click target is outside viewport or covered: ", selector)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                    button = "left", clickCount = 1L)
  }
  probe <- function(expression) paste0(
    "(()=>{const p=JSON.parse(document.getElementById('file_probe').textContent);return ", expression, "})()"
  )
  send <- function(id) {
    click(paste0("#", id, " .aui-lexical-input[contenteditable=true]"))
    browser$Input$insertText(text = "Show live file references")
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    check(paste(id, "real composer reply"), wait_js(sprintf(
      "document.getElementById('%s').innerText.includes('LIVE_FILES_READY')", id
    )))
  }
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  check("three installed widgets mount", wait_js(
    "['chat','other','plain'].every(id=>!!document.querySelector(`#${id} .aui-thread-root`))", 25
  ))
  check("history appears", wait_js(
    "[...document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')].some(e=>e.textContent.includes('Confirmed file history'))"
  ))
  value("[...document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')].find(e=>e.textContent.includes('Confirmed file history')).setAttribute('data-file-history','true');true")
  click("#chat [data-file-history=true] button")
  check("history restores before clicking any file", wait_js(
    "document.getElementById('chat').innerText.includes('HISTORY_FILES_READY')"
  ))
  check("known references receive backend-confirmed targets", wait_js(
    "['exists.R','known.R','nested.R','gone.R','~/.config/example/prefs.json'].every(path=>[...document.querySelectorAll('#chat code[data-file-ref]')].some(e=>e.dataset.fileRef===path&&e.getAttribute('role')==='button'))"
  ))
  check("Bash-only, missing and ambiguous references are gray and noninteractive", isTRUE(value(
    "['settings.json','missing.R','dm.R'].every(path=>{const e=[...document.querySelectorAll('#chat code[data-file-ref-candidate]')].find(e=>e.dataset.fileRefCandidate===path);return e&&e.classList.contains('bg-muted')&&!e.className.includes('bg-blue')&&!e.className.includes('underline')&&!e.hasAttribute('tabindex')&&!e.hasAttribute('role')&&getComputedStyle(e).cursor!=='pointer'})"
  )))
  check("unresolved references use a different actual background from confirmed links", isTRUE(value(
    "(()=>{const gray=document.querySelector('#chat code[data-file-ref-candidate=\"settings.json\"]'),blue=document.querySelector('#chat code[data-file-ref=\"exists.R\"]'),g=getComputedStyle(gray),b=getComputedStyle(blue);return g.backgroundColor!==b.backgroundColor&&g.color!==b.color&&g.textDecorationLine==='none'&&b.textDecorationLine.includes('underline')})()"
  )))
  check("duplicate inline references share one confirmation", wait_js(probe(
    "p.checked.filter(x=>x.path==='exists.R').length===1"
  )))
  click("#chat code[data-file-ref-candidate='settings.json']")
  check("unresolved filename click cannot dispatch navigation", isTRUE(value(probe("p.opened.length===0"))))
  before_checked <- value(probe("p.checked.length"))
  before_request <- value("Shiny.shinyapp.$inputValues.chat_input_resolve_files.requestId")
  value(paste0(
    "document.addEventListener('pointerdown',function refreshOnPress(e){",
    "if(!e.target.closest?.('#chat code[data-file-ref=\"exists.R\"]'))return;",
    "document.removeEventListener('pointerdown',refreshOnPress,true);",
    "Shiny.setInputValue('recheck_on_press',Date.now(),{priority:'event'});},true);true"
  ))
  value("document.querySelector('#chat code[data-file-ref=\"exists.R\"]').scrollIntoView({block:'center',behavior:'instant'});true")
  Sys.sleep(0.1)
  press <- value(paste0(
    "(()=>{const e=document.querySelector('#chat code[data-file-ref=\"exists.R\"]'),r=e.getBoundingClientRect();",
    "const x=r.x+r.width/2,y=r.y+r.height/2;window.__pressedFile=e;",
    "return {x,y,visible:r.width>0&&r.height>0&&x>=0&&y>=0&&x<innerWidth&&y<innerHeight&&e.contains(document.elementFromPoint(x,y))}})()"
  ))
  check("first pointer target is visible and unobscured", press$visible)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = press$x, y = press$y,
                                  button = "left", clickCount = 1L)
  check("history refresh starts while the first pointer press is held", wait_js(paste0(
    "Shiny.shinyapp.$inputValues.chat_input_resolve_files.requestId!==", quoted(before_request)
  )))
  check("confirmed link retains its DOM node and click handler during revalidation", isTRUE(value(
    "window.__pressedFile.isConnected&&window.__pressedFile.getAttribute('role')==='button'&&window.__pressedFile===document.querySelector('#chat code[data-file-ref=\"exists.R\"]')"
  )))
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = press$x, y = press$y,
                                  button = "left", clickCount = 1L)
  check("confirmed historical reference opens the exact path and line", wait_js(probe(sprintf(
    "p.opened.length===1&&p.opened[0].path===%s&&p.opened[0].line===7",
    quoted(file.path(root, "project", "exists.R"))
  ))))
  check("the first open is serviced before the slow confirmation batch finishes", isTRUE(value(probe(sprintf(
    "p.opened[0].checkedCount<%d", 2L * before_checked
  )))))
  check("opening feedback ends on the actual acknowledgement", wait_js(
    "document.querySelector('#chat code[data-file-ref=\"exists.R\"]')?.dataset.fileOpenState==='idle'"
  ))
  value("[...document.querySelectorAll('#chat code[data-file-ref=\"exists.R\"]')].find(e=>e.textContent==='exists.R:9').setAttribute('data-same-file-line','true');true")
  click("#chat [data-same-file-line=true]")
  check("an already-open file still accepts an explicit new line", wait_js(probe(sprintf(
    "p.opened.length===2&&p.opened[1].path===%s&&p.opened[1].line===9",
    quoted(file.path(root, "project", "exists.R"))
  ))))
  click("#chat code[data-file-ref='~/.config/example/prefs.json']")
  check("explicit home reference expands only inside synthetic Home", wait_js(probe(sprintf(
    "p.opened.length===3&&p.opened[2].path===%s&&p.opened[2].line===13",
    quoted(file.path(home, ".config", "example", "prefs.json"))
  ))))
  send("other")
  click("#other code[data-file-ref='exists.R']")
  check("another widget resolves the same basename in its own project", wait_js(probe(sprintf(
    "p.opened.length===4&&p.opened[3].path===%s&&p.opened[3].line===17",
    quoted(file.path(root, "other", "exists.R"))
  ))))
  send("plain")
  check("host without file opening never promises clickable file links", wait_js(
    "!!document.querySelector('#plain code[data-file-ref-candidate=\"exists.R\"]')&&!document.querySelector('#plain code[data-file-ref]')"
  ))
  send("chat")
  check("live unresolved references also remain noninteractive", wait_js(
    "document.querySelectorAll('#chat code[data-file-ref-candidate=\"settings.json\"]').length>=2"
  ))
  click("#remove_file")
  Sys.sleep(0.2)
  click("#chat code[data-file-ref='gone.R']")
  check("a file deleted after confirmation reports failure rather than silent success", wait_js(
    "document.querySelector('.shiny-notification')?.textContent.includes('Unable to locate file')"
  ))
  check("missing-on-click does not call IDE navigation", isTRUE(value(probe("p.opened.length===4"))))
  check("failed navigation is not displayed as successful completion", wait_js(
    "document.querySelector('#chat code[data-file-ref=\"gone.R\"]')?.dataset.fileOpenState==='failed'"
  ))
  click("#chat code[data-file-ref='slow.R']")
  check("deferred navigation has entered the pending state", wait_js(
    "document.querySelector('#chat code[data-file-ref=\"slow.R\"]')?.dataset.fileOpenState==='opening'"
  ))
  Sys.sleep(1.7)
  check("pending navigation is not cleared by the old 1.5 second timer", isTRUE(value(
    "document.querySelector('#chat code[data-file-ref=\"slow.R\"]')?.dataset.fileOpenState==='opening'"
  )))
  click("#chat code[data-file-ref='slow.R']")
  check("repeated pending clicks do not duplicate the backend open", isTRUE(value(probe(
    "p.openRequests.filter(x=>x.path.endsWith('/slow.R')).length===1"
  ))))
  click("#finish_open")
  check("the deferred open settles only after the editor callback completes", wait_js(probe(
    "p.opened.length===5&&p.opened[4].path.endsWith('/slow.R')"
  )) && wait_js(
    "document.querySelector('#chat code[data-file-ref=\"slow.R\"]')?.dataset.fileOpenState==='idle'"
  ))
  check("zero console errors", length(errors) == 0L)
  check("zero runtime exceptions", length(exceptions) == 0L)
  check("zero direct window errors", length(window_errors()) == 0L)
  check("zero failed network requests", length(network) == 0L)
  cat("BROWSER_RESULT checks=", checks,
      " console_errors=0 runtime_exceptions=0 window_errors=0 network_errors=0\n", sep = "")
}

main()
