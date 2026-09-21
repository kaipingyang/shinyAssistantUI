run_addin_session_independence <- function() {
  project <- normalizePath(".")
  installed <- normalizePath(find.package("shinyAssistantUI"))
  sdk <- normalizePath(find.package("ClaudeAgentSDK"))
  home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(
    identical(installed, file.path(home_library, "shinyAssistantUI")),
    identical(sdk, file.path(home_library, "ClaudeAgentSDK")),
    !identical(Sys.getenv("R_ENABLE_JIT"), "0")
  )
  output <- Sys.getenv("AUI_INDEPENDENCE_OUT", "")
  mode <- Sys.getenv("AUI_INDEPENDENCE_MODE", "normal")
  stopifnot(nzchar(output), mode %in% c("normal", "cancel"))
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  root <- tempfile("addin-independence-")
  dir.create(root, mode = "0700")
  browser <- app <- NULL
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    if (!is.null(browser)) {
      tryCatch({
        snapshot <- browser$Runtime$evaluate(
          "window.__independence", returnByValue = TRUE
        )$result$value
        if (!is.null(snapshot)) saveRDS(snapshot, file.path(output, "last-browser-observations.rds"))
      }, error = function(error) message("Browser observation cleanup: ", conditionMessage(error)))
    }
    cleanup()
    for (name in c("app.err", "app.out", "peer-events.jsonl")) {
      path <- file.path(root, name)
      if (file.exists(path)) file.copy(path, file.path(output, name), overwrite = TRUE)
    }
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  sessions <- setNames(
    paste0(c("11111111", "22222222", "33333333"), "-1111-4111-8111-111111111111"),
    c("Alpha", "Beta", "Gamma")
  )
  port <- httpuv::randomPort()
  stderr <- file.path(root, "app.err")
  app <- callr::r_bg(function(project, root, sessions, port, installed, sdk) {
    config <- file.path(root, "claude-config")
    Sys.setenv(
      HOME = root, CLAUDE_CONFIG_DIR = config, AUI_LONG_TASK_ROOT = root,
      AUI_LONG_TASK_SECONDS = "5", CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK = "1"
    )
    options(shiny.deepstacktrace = TRUE)
    stopifnot(
      file.copy(file.path(project, "tests/verify/fixtures/claude_concurrent_sessions.py"),
                file.path(root, "claude")),
      file.copy(file.path(project, "tests/verify/fixtures/claude_long_tasks.py"), root)
    )
    Sys.chmod(file.path(root, "claude"), "0755")
    Sys.setenv(PATH = paste(root, Sys.getenv("PATH"), sep = .Platform$path.sep))
    suppressPackageStartupMessages({
      library(shiny)
      library(shinyAssistantUI)
      library(ClaudeAgentSDK)
    })
    stopifnot(
      identical(normalizePath(find.package("shinyAssistantUI")), installed),
      identical(normalizePath(find.package("ClaudeAgentSDK")), sdk)
    )
    transcript_dir <- file.path(config, "projects", gsub("[^a-zA-Z0-9]", "-", root))
    dir.create(transcript_dir, recursive = TRUE)
    for (title in names(sessions)) {
      sid <- sessions[[title]]
      records <- list(
        list(
          type = "user", uuid = paste0("history-user-", title), parentUuid = NULL,
          sessionId = sid, cwd = root, timestamp = "2026-09-21T00:00:00Z",
          message = list(role = "user", content = title)
        ),
        list(
          type = "assistant", uuid = paste0("history-answer-", title),
          parentUuid = paste0("history-user-", title), sessionId = sid,
          cwd = root, timestamp = "2026-09-21T00:00:01Z",
          message = list(role = "assistant", content = list(list(
            type = "text", text = paste0("HISTORY_", toupper(title), "_READY")
          )))
        )
      )
      writeLines(vapply(records, function(record) as.character(jsonlite::toJSON(
        record, auto_unbox = TRUE, null = "null"
      )), ""), file.path(transcript_dir, paste0(sid, ".jsonl")))
    }
    settings <- shinyAssistantUI:::.write_addin_settings(list(autoStartCopilotApi = FALSE))
    stopifnot(identical(settings$autoStartCopilotApi, FALSE))
    app <- shinyAssistantUI:::.claude_chat_app(
      project = root, prewarm = FALSE, diagnostics = TRUE,
      memory_guard_config = list(enabled = TRUE),
      options = ClaudeAgentOptions(
        cwd = root, cli_path = file.path(root, "claude"),
        permission_mode = "default", permission_prompt_tool_name = "stdio",
        include_partial_messages = TRUE
      )
    )
    server_source <- app$serverFuncSource
    app$serverFuncSource <- function() {
      original <- server_source()
      function(input, output, session) {
        original(input, output, session)
        reported_initialization <- FALSE
        observe({
          invalidateLater(100, session)
          session$sendCustomMessage("independence:heartbeat", list(at = as.numeric(Sys.time())))
          signal <- file.path(root, "beta-initializing.json")
          if (!reported_initialization && file.exists(signal)) {
            reported_initialization <<- TRUE
            session$sendCustomMessage("independence:initializing", jsonlite::fromJSON(signal))
          }
        })
        observeEvent(input$independence_ping, {
          session$sendCustomMessage("independence:pong", input$independence_ping)
        }, ignoreInit = TRUE)
        observeEvent(input$chat_input_cancel, {
          cat("CANCEL_RECEIVED ", sprintf("%.6f", as.numeric(Sys.time())), "\n", sep = "")
          flush.console()
        }, ignoreInit = TRUE, priority = 1000)
      }
    }
    runApp(app, host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(
    project = project, root = root, sessions = sessions, port = port,
    installed = installed, sdk = sdk
  ), stdout = file.path(root, "app.out"), stderr = stderr, supervise = TRUE,
  user_profile = FALSE, system_profile = FALSE)
  wait <- function(predicate, label, timeout = 20) {
    deadline <- Sys.time() + timeout
    repeat {
      if (!app$is_alive()) {
        cat(readLines(stderr, warn = FALSE), sep = "\n")
        stop("Installed addin exited")
      }
      if (isTRUE(predicate())) return(invisible(TRUE))
      if (Sys.time() > deadline) {
        cat(tail(readLines(stderr, warn = FALSE), 25), sep = "\n")
        stop("Independence check timed out: ", label)
      }
      Sys.sleep(0.05)
    }
  }
  wait(function() file.exists(stderr) && any(grepl(
    "Listening on", readLines(stderr, warn = FALSE), fixed = TRUE
  )), "addin listening")
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- chromote::ChromoteSession$new(width = 1200, height = 900)
  errors <- list()
  browser$Runtime$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors[[length(errors) + 1L]] <<- event
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors[[length(errors) + 1L]] <<- event
  })
  browser$Page$addScriptToEvaluateOnNewDocument(source = paste0(
    "document.addEventListener('DOMContentLoaded',()=>{",
    "const icon=document.createElement('link');icon.rel='icon';",
    "icon.href='data:,';document.head.append(icon);});"
  ))
  js <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) {
      details <- result$exceptionDetails
      stop("Browser observation failed: ", paste(
        details$text, details$exception$description, details$exception$value,
        collapse = " "
      ))
    }
    result$result$value
  }
  check <- function(label, code, timeout = 20) {
    wait(function() isTRUE(js(code)), label, timeout)
    cat("[PASS] ", label, "\n", sep = "")
  }
  literal <- function(value) as.character(jsonlite::toJSON(value, auto_unbox = TRUE))
  has <- function(value) paste0("document.body.innerText.includes(", literal(value), ")")
  select <- function(title) {
    check(paste("select", title), paste0(
      "(()=>{const r=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')]",
      ".find(r=>r.innerText.includes(", literal(title), "));",
      "const b=r?.querySelector('[data-slot=aui_thread-list-item-trigger]');",
      "if(!b)return false;b.click();return true;})()"
    ))
    wait(function() isTRUE(js(has(paste0("HISTORY_", toupper(title), "_READY")))),
         paste("selected history is rendered", title))
  }
  send <- function(text) {
    check("real composer ready", "!!document.querySelector('.aui-composer-send')")
    js("document.querySelector('[contenteditable=true]').focus(); true")
    browser$Input$insertText(text)
    check("composer send enabled", "!!document.querySelector('.aui-composer-send:not([disabled])')")
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                  windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                  windowsVirtualKeyCode = 13L)
  }
  stop_current <- function() {
    check("current thread Stop available", "!!document.querySelector('.aui-composer-cancel')")
    js("document.querySelector('.aui-composer-cancel').click(); true")
    check("only current thread settles", "!!document.querySelector('.aui-composer-send')")
  }
  browser$Page$navigate(paste0("http://127.0.0.1:", port))
  check("real installed addin mounted", "!!document.querySelector('.aui-root')")
  js(paste0(
    "window.__independence={heartbeats:[],chunks:[],pongs:[],cancels:[],phases:[]};",
    "Shiny.addCustomMessageHandler('independence:heartbeat',message=>",
    "window.__independence.heartbeats.push(performance.now()));",
    "Shiny.addCustomMessageHandler('independence:pong',v=>",
    "window.__independence.pongs.push({sent:v.at,received:performance.now()}));",
    "Shiny.addCustomMessageHandler('independence:initializing',v=>{",
    "window.__independence.initializingPid=v.pid;",
    if (identical(mode, "cancel")) paste0(
      "if(window.__independence.cancelAt===undefined){",
      "const cancel=document.querySelector('[data-slot=aui_run_cancel]');",
      "if(!cancel)throw new Error('Initialization Cancel button is missing');",
      "window.__independence.cancelAt=performance.now();",
      "cancel.click();}"
    ) else "",
    "});",
    "window.jQuery(document).on('shiny:message.independence',e=>{",
    "const c=e.message?.custom?.['chat_input:chunk'];",
    "if(c)window.__independence.chunks.push({threadId:c.threadId,at:performance.now(),text:c.text});",
    "const p=e.message?.custom?.['chat_input:run-state'];",
    "if(p)window.__independence.phases.push({...p,at:performance.now(),wall:Date.now()});",
    "});",
    "window.jQuery(document).on('shiny:inputchanged.independence',e=>{",
    "if(e.name==='chat_input_cancel')window.__independence.cancels.push({",
    "value:e.value,at:performance.now(),wall:Date.now()});",
    "});true"
  ))
  select("Alpha")
  check("Alpha authoritative history restored", has("HISTORY_ALPHA_READY"))
  send("AUI_STREAM")
  check("Alpha is continuously streaming", has("ALPHA_0010"))
  baseline_end <- js("performance.now()")
  select("Beta")
  check("Beta authoritative history restored", has("HISTORY_BETA_READY"))
  cold_begin <- js("performance.now()")
  js(paste0(
    "setTimeout(()=>{Shiny.setInputValue('independence_ping',",
    "{at:performance.now(),nonce:1},{priority:'event'});},1000);true"
  ))
  send("AUI_STREAM")
  cancelled_connection_ms <- NULL
  if (identical(mode, "cancel")) {
    peer_rows <- function() lapply(
      readLines(file.path(root, "peer-events.jsonl"), warn = FALSE),
      jsonlite::fromJSON, simplifyVector = FALSE
    )
    check("real initializing CLI triggers browser Cancel",
          "typeof window.__independence.cancelAt==='number'")
    initializing_pid <- js("window.__independence.initializingPid")
    check("cancelled cold connection leaves Beta composer usable",
          "!document.querySelector('[data-slot=aui_run_cancel]')&&!!document.querySelector('.aui-composer-send')")
    wait(function() !dir.exists(file.path("/proc", initializing_pid)), "cancelled CLI exits", 3)
    cancelled_connection_ms <- js("performance.now()-window.__independence.cancelAt")
    beta <- Filter(function(value) isTRUE(value$pid == initializing_pid), peer_rows())
    stopifnot(
      length(beta) >= 1L,
      !any(vapply(beta, function(value) identical(value$kind, "prompt"), FALSE))
    )
    cat("[PASS] cancelled initialize sends no prompt and retires only its CLI\n")
    send("AUI_STREAM")
  }
  check("Beta starts while Alpha is still active", has("BETA_0005"))
  cold_end <- js("performance.now()")
  saveRDS(js("window.__independence"), file.path(output, "cold-observations.rds"))
  check("both sidebar histories report running",
        "document.querySelectorAll('[data-slot=aui_thread-list-run-phase][data-run-phase=running]').length===2")
  warm_begin <- js("performance.now()")
  Sys.sleep(2)
  check("Beta keeps progressing", has("BETA_0020"))
  select("Alpha")
  check("Alpha received updates while its history was not selected", has("ALPHA_0030"))
  warm_end <- js("performance.now()")
  select("Gamma")
  check("third history restored", has("HISTORY_GAMMA_READY"))
  send("AUI_QUICK")
  check("Gamma queues behind two running histories",
        "document.querySelectorAll('[data-slot=aui_thread-list-run-phase][data-run-phase=queued]').length===1")
  stopifnot(!isTRUE(js(has("GAMMA_QUICK_DONE"))))
  select("Alpha")
  stop_current()
  select("Gamma")
  check("stopping Alpha admits queued Gamma", has("GAMMA_QUICK_DONE"))
  select("Beta")
  check("stopping Alpha did not stop Beta", "!!document.querySelector('.aui-composer-cancel')")
  select("Alpha")
  send("AUI_APPROVAL")
  check("Alpha approval appears", "[...document.querySelectorAll('button')].some(b=>b.innerText.trim()==='Approve')")
  approval_begin <- js("performance.now()")
  Sys.sleep(2)
  select("Beta")
  check("Beta remains active during Alpha approval", "!!document.querySelector('.aui-composer-cancel')")
  select("Alpha")
  check("Alpha approval survives switching back",
        "[...document.querySelectorAll('button')].some(b=>b.innerText.trim()==='Approve')")
  js("[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve').click();true")
  check("Alpha approval completes independently", has("ALPHA_APPROVAL_DONE"))
  approval_end <- js("performance.now()")
  select("Beta")
  stop_current()
  observed <- js("window.__independence")
  saveRDS(observed, file.path(output, "browser-observations.rds"))
  browser$Page$reload()
  browser$Page$loadEventFired()
  check("addin remounts after independent turns", "!!document.querySelector('.aui-root')")
  select("Alpha")
  check("canonical history keeps the completed approval reply", has("ALPHA_APPROVAL_DONE"))
  check("reload does not restore a running history badge",
        "document.querySelectorAll('[data-slot=aui_thread-list-run-phase]').length===0")
  timestamps <- function(values) as.numeric(unlist(values, use.names = FALSE))
  heartbeats <- timestamps(observed$heartbeats)
  chunks <- observed$chunks
  chunk_times <- function(tid, begin = -Inf, end = Inf) {
    values <- vapply(Filter(function(value) {
      identical(value$threadId, tid) && value$at >= begin && value$at <= end
    }, chunks), `[[`, 0, "at")
    sort(values)
  }
  gap <- function(values) if (length(values) < 2L) Inf else max(diff(values))
  report <- list(
    installed = installed, sdk = sdk, mode = mode,
    cancelled_connection_ms = cancelled_connection_ms,
    baseline_heartbeat_gap_ms = gap(heartbeats[heartbeats <= baseline_end]),
    cold_heartbeat_gap_ms = gap(heartbeats[
      heartbeats >= cold_begin - 150 & heartbeats <= cold_end
    ]),
    cold_alpha_chunk_gap_ms = gap(chunk_times(sessions[["Alpha"]], cold_begin - 300, cold_end)),
    cold_beta_start_ms = cold_end - cold_begin,
    cold_ping_roundtrip_ms = if (length(observed$pongs)) {
      observed$pongs[[1L]]$received - observed$pongs[[1L]]$sent
    } else Inf,
    warm_alpha_chunk_gap_ms = gap(chunk_times(sessions[["Alpha"]], warm_begin, warm_end)),
    warm_beta_chunk_gap_ms = gap(chunk_times(sessions[["Beta"]], warm_begin, warm_end)),
    beta_chunks_during_alpha_approval = length(chunk_times(
      sessions[["Beta"]], approval_begin, approval_end
    )),
    console_runtime_errors = length(errors)
  )
  print(report)
  saveRDS(report, file.path(output, "independence-report.rds"))
  if (length(errors)) saveRDS(errors, file.path(output, "browser-errors.rds"))
  cleanup()
  browser <- NULL
  stopifnot(
    report$console_runtime_errors == 0L,
    report$baseline_heartbeat_gap_ms < 1000,
    report$cold_heartbeat_gap_ms < 1000,
    report$cold_alpha_chunk_gap_ms < 1000,
    report$cold_ping_roundtrip_ms < 1000,
    report$warm_alpha_chunk_gap_ms < 1000,
    report$warm_beta_chunk_gap_ms < 1000,
    report$beta_chunks_during_alpha_approval >= 10L
  )
  if (!is.null(cancelled_connection_ms)) stopifnot(cancelled_connection_ms < 1000)
  cat("INSTALLED_ADDIN_SESSION_INDEPENDENCE_PASSED cleanup=true\n")
}

run_addin_session_independence()
