# Plan 93 — shared lifecycle for ordinary Claude Chat and Claude Workspace.
# Real RStudio Jobs-pane/proxy semantics remain a separate manual smoke test.

.bg_registry <- function() new.env(parent = emptyenv())
.bg_spec <- function(workspace = FALSE, project = "/proj", permission = "default",
                     projects = NULL, options = NULL) {
  list(
    project = project,
    options = options,
    permission_mode = permission,
    prewarm = FALSE,
    models = NULL,
    console_url = "ipc:///tmp/shared-console.sock",
    workspace = workspace,
    workspace_projects = projects,
    job_name = if (workspace) "Claude Workspace" else "Claude Code Chat"
  )
}

test_that("launch script embeds lifecycle identity, log path, and remains parseable", {
  s <- shinyAssistantUI:::.claude_bg_launch_script(
    "/tmp/spec.rds", 4321L, "127.0.0.1", c("/lib/a", "/lib/b"),
    log_path = "/tmp/lifecycle.log", nonce = "nonce-123", mode = "chat"
  )
  txt <- paste(s, collapse = "\n")
  expect_match(txt, "library(shinyAssistantUI)", fixed = TRUE)
  expect_match(txt, ".libPaths(", fixed = TRUE)
  expect_match(txt, '"/lib/a"', fixed = TRUE)
  expect_match(txt, '"/lib/b"', fixed = TRUE)
  expect_match(txt, ".claude_run_in_job(", fixed = TRUE)
  expect_match(txt, '"/tmp/spec.rds"', fixed = TRUE)
  expect_match(txt, "4321L", fixed = TRUE)
  expect_match(txt, 'log_path = "/tmp/lifecycle.log"', fixed = TRUE)
  expect_match(txt, 'nonce = "nonce-123"', fixed = TRUE)
  expect_match(txt, 'mode = "chat"', fixed = TRUE)
  expect_silent(parse(text = txt))
})

test_that("request keys and fingerprints isolate mode, project, order, and config", {
  chat <- .bg_spec(FALSE, "/proj")
  workspace <- .bg_spec(TRUE, "/proj", projects = c("/b", "/a"))
  workspace_reordered <- .bg_spec(TRUE, "/proj", projects = c("/a", "/b"))
  plan <- .bg_spec(FALSE, "/proj", permission = "plan")

  expect_false(identical(
    shinyAssistantUI:::.claude_bg_registry_key(chat),
    shinyAssistantUI:::.claude_bg_registry_key(workspace)
  ))
  expect_false(identical(
    shinyAssistantUI:::.claude_bg_request_fingerprint(chat),
    shinyAssistantUI:::.claude_bg_request_fingerprint(plan)
  ))
  expect_false(identical(
    shinyAssistantUI:::.claude_bg_request_fingerprint(workspace),
    shinyAssistantUI:::.claude_bg_request_fingerprint(workspace_reordered)
  ))
  changed_console <- chat
  changed_console$console_url <- "ipc:///tmp/another.sock"
  expect_identical(
    shinyAssistantUI:::.claude_bg_request_fingerprint(chat),
    shinyAssistantUI:::.claude_bg_request_fingerprint(changed_console)
  )
})

test_that("instance response requires the exact nonce and mode markers", {
  good <- c(
    "HTTP/1.1 200 OK", "", '<meta name="shinyassistant-bg-nonce" content="abc-123"/>',
    '<meta name="shinyassistant-bg-mode" content="workspace"/>'
  )
  match <- shinyAssistantUI:::.claude_bg_response_matches
  expect_true(match(good, "abc-123", "workspace"))
  expect_false(match(good, "wrong", "workspace"))
  expect_false(match(good, "abc-123", "chat"))
  expect_false(match(c("HTTP/1.1 200 OK", "", "partial"), "abc-123", "workspace"))
})

test_that("first launch captures Job ID, lifecycle record, and legacy return fields", {
  spec <- .bg_spec(FALSE, permission = "plan")
  seen <- new.env(parent = emptyenv())
  registry <- .bg_registry()
  res <- shinyAssistantUI:::.run_claude_bg_job(
    spec, host = "127.0.0.1", port = 4321L, libpaths = c("/lib/x"),
    registry = registry,
    nonce_factory = function() "chat-nonce",
    log_path = "/tmp/chat-lifecycle.log",
    job_run = function(path, name, workingDir) {
      seen$path <- path; seen$name <- name; seen$wd <- workingDir
      "JOB-CHAT-1"
    },
    show_viewer = function(u) seen$url <- u,
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) FALSE,
    job_state = function(id) "running"
  )

  expect_identical(res$port, 4321L)
  expect_identical(res$url, "http://127.0.0.1:4321")
  expect_true(res$ready)
  expect_false(res$reused)
  expect_identical(res$job_id, "JOB-CHAT-1")
  expect_identical(res$nonce, "chat-nonce")
  expect_identical(res$mode, "chat")
  expect_identical(seen$name, "Claude Code Chat")
  expect_identical(seen$wd, "/proj")
  expect_identical(seen$url, res$url)
  rt <- readRDS(res$spec_path)
  expect_identical(rt$permission_mode, "plan")
  expect_identical(rt$console_url, spec$console_url)
  expect_identical(rt$.claude_bg_nonce, "chat-nonce")
  expect_identical(rt$.claude_bg_mode, "chat")

  key <- shinyAssistantUI:::.claude_bg_registry_key(spec)
  record <- get(key, envir = registry, inherits = FALSE)
  expect_identical(record$job_id, "JOB-CHAT-1")
  expect_identical(record$status, "ready")
  expect_identical(record$generation, 1L)
})

test_that("healthy identical Chat and Workspace reopen without duplicate launch", {
  registry <- .bg_registry()
  launches <- ports <- waits <- 0L
  shown <- character()
  next_port <- function() { ports <<- ports + 1L; 4400L + ports }
  launch <- function(path, name, workingDir) {
    launches <<- launches + 1L
    paste0("JOB-", launches)
  }
  wait <- function(host, port) { waits <<- waits + 1L; TRUE }
  probe <- function(host, port, nonce, mode) TRUE
  state <- function(id) "running"

  run <- function(spec) shinyAssistantUI:::.run_claude_bg_job(
    spec, registry = registry, port_factory = next_port,
    nonce_factory = function() paste0("nonce-", launches + 1L),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = launch, wait_ready = wait, instance_probe = probe,
    job_state = state, show_viewer = function(u) shown <<- c(shown, u)
  )

  c1 <- run(.bg_spec(FALSE))
  c2 <- run(.bg_spec(FALSE))
  w1 <- run(.bg_spec(TRUE, projects = c("/proj", "/other")))
  w2 <- run(.bg_spec(TRUE, projects = c("/proj", "/other")))

  expect_false(c1$reused)
  expect_true(c2$reused)
  expect_identical(c2$job_id, c1$job_id)
  expect_identical(c2$port, c1$port)
  expect_false(w1$reused)
  expect_true(w2$reused)
  expect_identical(w2$job_id, w1$job_id)
  expect_false(identical(w1$job_id, c1$job_id))
  expect_identical(launches, 2L)
  expect_identical(ports, 2L)
  expect_identical(waits, 2L)
  expect_length(shown, 4L)
  expect_length(ls(registry), 2L)
})

test_that("terminal stale record launches a new generation and port", {
  registry <- .bg_registry()
  launches <- ports <- 0L
  ids <- character()
  run <- function() shinyAssistantUI:::.run_claude_bg_job(
    .bg_spec(FALSE), registry = registry,
    port_factory = function() { ports <<- ports + 1L; 4500L + ports },
    nonce_factory = function() paste0("nonce-", ports + 1L),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = function(path, name, workingDir) {
      launches <<- launches + 1L; id <- paste0("JOB-", launches)
      ids <<- c(ids, id); id
    },
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) FALSE,
    job_state = function(id) if (identical(id, "JOB-1")) "failed" else "running",
    show_viewer = function(u) NULL
  )

  one <- run()
  two <- run()
  expect_identical(c(one$generation, two$generation), c(1L, 2L))
  expect_false(two$reused)
  expect_false(identical(two$job_id, one$job_id))
  expect_false(identical(two$port, one$port))
  expect_identical(launches, 2L)
  expect_identical(ports, 2L)
})

test_that("active unhealthy record is waited without duplicate launch", {
  registry <- .bg_registry()
  launches <- waits <- 0L
  run <- function() shinyAssistantUI:::.run_claude_bg_job(
    .bg_spec(TRUE, projects = "/proj"), registry = registry, port = 4601L,
    nonce_factory = function() "workspace-nonce",
    log_path = "/tmp/workspace-lifecycle.log",
    job_run = function(path, name, workingDir) {
      launches <<- launches + 1L; "JOB-WORKSPACE"
    },
    wait_ready = function(host, port) {
      waits <<- waits + 1L
      waits == 1L
    },
    instance_probe = function(...) FALSE,
    job_state = function(id) "running",
    show_viewer = function(u) NULL
  )

  expect_true(run()$ready)
  expect_error(run(), "existing Claude Workspace.*did not become ready")
  expect_identical(launches, 1L)
  expect_identical(waits, 2L)
})

test_that("known terminal state rejects an open but stale or reused port", {
  registry <- .bg_registry()
  launches <- 0L
  run <- function() shinyAssistantUI:::.run_claude_bg_job(
    .bg_spec(FALSE), registry = registry,
    port_factory = function() 4700L + launches + 1L,
    nonce_factory = function() paste0("nonce-", launches + 1L),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = function(path, name, workingDir) {
      launches <<- launches + 1L; paste0("JOB-", launches)
    },
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) TRUE,
    job_state = function(id) if (identical(id, "JOB-1")) "cancelled" else "running",
    show_viewer = function(u) NULL
  )

  one <- run()
  two <- run()
  expect_identical(launches, 2L)
  expect_false(two$reused)
  expect_false(identical(one$job_id, two$job_id))
})

test_that("incompatible request fingerprint starts a new tracked generation", {
  registry <- .bg_registry()
  launches <- 0L
  run <- function(spec) shinyAssistantUI:::.run_claude_bg_job(
    spec, registry = registry, port_factory = function() 4800L + launches + 1L,
    nonce_factory = function() paste0("nonce-", launches + 1L),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = function(path, name, workingDir) {
      launches <<- launches + 1L; paste0("JOB-", launches)
    },
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) TRUE,
    job_state = function(id) "running",
    show_viewer = function(u) NULL
  )
  one <- run(.bg_spec(FALSE, permission = "default"))
  two <- run(.bg_spec(FALSE, permission = "plan"))
  expect_identical(launches, 2L)
  expect_false(two$reused)
  expect_false(identical(one$job_id, two$job_id))
})

test_that("submission failure preserves the previously tracked record", {
  registry <- .bg_registry()
  good <- shinyAssistantUI:::.run_claude_bg_job(
    .bg_spec(FALSE), registry = registry, port = 4901L,
    nonce_factory = function() "good-nonce", log_path = "/tmp/good.log",
    job_run = function(path, name, workingDir) "GOOD-JOB",
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) TRUE,
    job_state = function(id) "running", show_viewer = function(u) NULL
  )
  expect_error(
    shinyAssistantUI:::.run_claude_bg_job(
      .bg_spec(FALSE, permission = "plan"), registry = registry, port = 4902L,
      nonce_factory = function() "bad-nonce", log_path = "/tmp/bad.log",
      job_run = function(path, name, workingDir) stop("submission exploded"),
      wait_ready = function(host, port) TRUE,
      instance_probe = function(...) FALSE,
      job_state = function(id) "running", show_viewer = function(u) NULL
    ),
    "submission exploded"
  )
  record <- get(shinyAssistantUI:::.claude_bg_registry_key(.bg_spec(FALSE)),
                envir = registry, inherits = FALSE)
  expect_identical(record$job_id, good$job_id)
  expect_identical(record$nonce, good$nonce)
})

test_that("startup timeout is actionable and never opens Viewer", {
  registry <- .bg_registry()
  shown <- FALSE
  expect_error(
    shinyAssistantUI:::.run_claude_bg_job(
      .bg_spec(TRUE, project = "/p", projects = "/p"), registry = registry,
      port = 5000L, nonce_factory = function() "timeout-nonce",
      log_path = "/tmp/workspace-timeout.log",
      job_run = function(path, name, workingDir) "JOB-TIMEOUT",
      show_viewer = function(u) shown <<- TRUE,
      wait_ready = function(host, port) FALSE,
      instance_probe = function(...) FALSE,
      job_state = function(id) "failed"
    ),
    "Claude Workspace.*127.0.0.1:5000.*JOB-TIMEOUT.*failed.*/tmp/workspace-timeout.log.*same.*Addin"
  )
  expect_false(shown)
})

test_that("lifecycle log uses an explicit allowlist and logger errors are non-fatal", {
  path <- tempfile(fileext = ".log")
  secret <- "DO_NOT_LOG_fixture_secret"
  expect_silent(shinyAssistantUI:::.claude_bg_log_event(
    path, "starting", mode = "chat", generation = 2L,
    nonce = "safe-nonce", port = 5001L, condition = simpleError(secret)
  ))
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  expect_match(text, "event=starting", fixed = TRUE)
  expect_match(text, "mode=chat", fixed = TRUE)
  expect_match(text, "condition_class=simpleError", fixed = TRUE)
  expect_false(grepl(secret, text, fixed = TRUE))
  expect_silent(shinyAssistantUI:::.claude_bg_log_event(
    file.path(path, "impossible", "child.log"), "failed", mode = "chat"
  ))
})

test_that(".claude_run_in_job forwards lifecycle markers for Chat and Workspace", {
  spec_path <- tempfile(fileext = ".rds")
  saveRDS(.bg_spec(TRUE, project = "/proj", permission = "acceptEdits",
                   projects = c("/proj", "/other")), spec_path)
  cap <- new.env(parent = emptyenv())
  testthat::local_mocked_bindings(
    .claude_chat_app = function(project, options, permission_mode, prewarm, models,
                                console_url = NULL, workspace = FALSE,
                                workspace_projects = NULL,
                                lifecycle_nonce = NULL, lifecycle_mode = NULL) {
      cap$args <- list(
        project = project, permission_mode = permission_mode,
        workspace = workspace, workspace_projects = workspace_projects,
        lifecycle_nonce = lifecycle_nonce, lifecycle_mode = lifecycle_mode
      )
      "APP_OBJ"
    }
  )
  testthat::local_mocked_bindings(
    runApp = function(app, port, host, launch.browser) {
      cap$app <- app; cap$port <- port; cap$host <- host; "RAN"
    },
    .package = "shiny"
  )
  shinyAssistantUI:::.claude_run_in_job(
    spec_path, port = 6001L, host = "127.0.0.1",
    log_path = tempfile(fileext = ".log"), nonce = "workspace-nonce", mode = "workspace"
  )
  expect_true(cap$args$workspace)
  expect_identical(cap$args$workspace_projects, c("/proj", "/other"))
  expect_identical(cap$args$lifecycle_nonce, "workspace-nonce")
  expect_identical(cap$args$lifecycle_mode, "workspace")
  expect_identical(cap$app, "APP_OBJ")
  expect_identical(cap$port, 6001L)
})


test_that("public Chat and Workspace entries forward independent specs with one stable console URL", {
  captured <- list()
  ensured <- 0L
  testthat::local_mocked_bindings(
    .addin_ensure_r_console_server = function(envir = globalenv(), ...) {
      ensured <<- ensured + 1L
      "ipc:///tmp/stable-public.sock"
    },
    .run_claude_bg_job = function(spec, ...) {
      captured[[length(captured) + 1L]] <<- spec
      list(mode = if (isTRUE(spec$workspace)) "workspace" else "chat")
    }
  )
  testthat::local_mocked_bindings(
    isAvailable = function(...) TRUE,
    .package = "rstudioapi"
  )

  chat <- claude_addin(project = "/project-one", background = TRUE)
  workspace <- claude_workspace_addin(
    project = "/project-one", projects = c("/project-two", "/project-one"),
    background = TRUE
  )

  expect_identical(chat$mode, "chat")
  expect_identical(workspace$mode, "workspace")
  expect_length(captured, 2L)
  expect_false(captured[[1L]]$workspace)
  expect_true(captured[[2L]]$workspace)
  expect_identical(captured[[2L]]$workspace_projects, c("/project-two", "/project-one"))
  expect_identical(captured[[1L]]$console_url, "ipc:///tmp/stable-public.sock")
  expect_identical(captured[[2L]]$console_url, captured[[1L]]$console_url)
  expect_identical(ensured, 2L)
})

test_that("a re-entrant newer generation cannot be overwritten by the older waiter", {
  registry <- .bg_registry()
  ports <- launches <- 0L
  inner <- NULL
  entered <- FALSE
  launch <- function(path, name, workingDir) {
    launches <<- launches + 1L
    paste0("JOB-", launches)
  }
  port_factory <- function() {
    ports <<- ports + 1L
    5100L + ports
  }
  common <- list(
    registry = registry,
    port_factory = port_factory,
    nonce_factory = function() paste0("nonce-", ports + 1L),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = launch,
    instance_probe = function(...) FALSE,
    job_state = function(id) "running",
    show_viewer = function(u) NULL
  )
  outer_wait <- function(host, port) {
    if (!entered) {
      entered <<- TRUE
      inner <<- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
        list(spec = .bg_spec(FALSE, permission = "plan"),
             wait_ready = function(host, port) TRUE),
        common
      ))
    }
    TRUE
  }
  outer <- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
    list(spec = .bg_spec(FALSE), wait_ready = outer_wait), common
  ))

  expect_true(outer$superseded)
  expect_false(inner$superseded)
  expect_identical(inner$generation, 2L)
  record <- get(shinyAssistantUI:::.claude_bg_registry_key(.bg_spec(FALSE)),
                envir = registry, inherits = FALSE)
  expect_identical(record$generation, 2L)
  expect_identical(record$job_id, inner$job_id)
  expect_identical(launches, 2L)
})

test_that("malformed registry records are never reused", {
  registry <- .bg_registry()
  spec <- .bg_spec(FALSE)
  assign(shinyAssistantUI:::.claude_bg_registry_key(spec), list(
    fingerprint = raw(), port = 5201L, url = "http://127.0.0.1:5201"
  ), envir = registry)
  launches <- 0L
  result <- shinyAssistantUI:::.run_claude_bg_job(
    spec, registry = registry, port = 5202L,
    nonce_factory = function() "fresh-nonce", log_path = tempfile(fileext = ".log"),
    job_run = function(path, name, workingDir) {
      launches <<- launches + 1L
      "FRESH-JOB"
    },
    wait_ready = function(host, port) TRUE,
    instance_probe = function(...) TRUE,
    job_state = function(id) "running",
    show_viewer = function(u) NULL
  )
  expect_identical(launches, 1L)
  expect_false(result$reused)
  expect_identical(result$generation, 1L)
  expect_identical(result$job_id, "FRESH-JOB")
})


test_that("re-entrant healthy probe cannot roll a newer generation back", {
  registry <- .bg_registry()
  launches <- 0L
  launch <- function(path, name, workingDir) {
    launches <<- launches + 1L
    paste0("PROBE-JOB-", launches)
  }
  common <- list(
    registry = registry,
    port_factory = local({ p <- 5300L; function() { p <<- p + 1L; p } }),
    nonce_factory = local({ n <- 0L; function() { n <<- n + 1L; paste0("probe-nonce-", n) } }),
    log_path_factory = function(...) tempfile(fileext = ".log"),
    job_run = launch,
    job_state = function(id) "running",
    wait_ready = function(host, port) TRUE,
    show_viewer = function(u) NULL
  )
  first <- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
    list(spec = .bg_spec(FALSE), instance_probe = function(...) FALSE), common
  ))
  inner <- NULL
  entered <- FALSE
  probe <- function(...) {
    if (!entered) {
      entered <<- TRUE
      inner <<- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
        list(spec = .bg_spec(FALSE, permission = "plan"),
             instance_probe = function(...) FALSE),
        common
      ))
    }
    TRUE
  }
  outer <- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
    list(spec = .bg_spec(FALSE), instance_probe = probe), common
  ))

  record <- get(shinyAssistantUI:::.claude_bg_registry_key(.bg_spec(FALSE)),
                envir = registry, inherits = FALSE)
  expect_true(outer$superseded)
  expect_identical(inner$generation, 2L)
  expect_identical(record$generation, 2L)
  expect_identical(record$job_id, inner$job_id)
  expect_false(identical(record$job_id, first$job_id))
})

test_that("re-entrant submission observes reservation and does not duplicate", {
  registry <- .bg_registry()
  launches <- 0L
  nested <- NULL
  entered <- FALSE
  common <- list(
    registry = registry, port_factory = function() 5401L,
    nonce_factory = function() "submission-nonce",
    log_path = tempfile(fileext = ".log"),
    instance_probe = function(...) FALSE,
    job_state = function(id) "running",
    wait_ready = function(host, port) TRUE,
    show_viewer = function(u) NULL
  )
  launch <- function(path, name, workingDir) {
    launches <<- launches + 1L
    if (!entered) {
      entered <<- TRUE
      nested <<- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
        list(spec = .bg_spec(FALSE, permission = "plan"),
             job_run = function(...) stop("must not launch nested")),
        common
      ))
    }
    "RESERVED-JOB"
  }
  outer <- do.call(shinyAssistantUI:::.run_claude_bg_job, c(
    list(spec = .bg_spec(FALSE), job_run = launch), common
  ))
  record <- get(shinyAssistantUI:::.claude_bg_registry_key(.bg_spec(FALSE)),
                envir = registry, inherits = FALSE)
  expect_identical(launches, 1L)
  expect_true(nested$in_progress)
  expect_identical(record$job_id, outer$job_id)
  expect_identical(record$status, "ready")
})

test_that("a changed run_r console URL prevents otherwise-compatible reuse", {
  registry <- .bg_registry()
  launches <- 0L
  run <- function(console_url) {
    spec <- .bg_spec(FALSE)
    spec$console_url <- console_url
    shinyAssistantUI:::.run_claude_bg_job(
      spec, registry = registry,
      port_factory = function() 5500L + launches + 1L,
      nonce_factory = function() paste0("console-nonce-", launches + 1L),
      log_path_factory = function(...) tempfile(fileext = ".log"),
      job_run = function(path, name, workingDir) {
        launches <<- launches + 1L
        paste0("CONSOLE-JOB-", launches)
      },
      wait_ready = function(host, port) TRUE,
      instance_probe = function(...) TRUE,
      job_state = function(id) "running",
      show_viewer = function(u) NULL
    )
  }
  one <- run("ipc:///tmp/console-one.sock")
  two <- run("ipc:///tmp/console-two.sock")
  expect_identical(launches, 2L)
  expect_false(two$reused)
  expect_false(identical(one$job_id, two$job_id))
})
