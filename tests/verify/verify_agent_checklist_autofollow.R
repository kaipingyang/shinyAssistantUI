source("tests/verify/owned_process_cleanup.R")

main <- function() {
  project <- normalizePath(".")
  installed <- normalizePath(find.package("shinyAssistantUI"))
  stopifnot(startsWith(installed, paste0(normalizePath(path.expand("~")), "/")))
  version <- as.character(utils::packageVersion("shinyAssistantUI"))
  port <- httpuv::randomPort()
  stdout <- tempfile("checklist-stdout-")
  stderr <- tempfile("checklist-stderr-")
  app <- NULL
  cleanup <- make_verification_cleanup(function() NULL, function() app, c(stdout, stderr))
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(
    function(project, installed, port) {
      setwd(project)
      Sys.setenv(SHINYASSISTANTUI_VERIFY_LIB = dirname(installed))
      library(shinyAssistantUI, lib.loc = dirname(installed))
      stopifnot(identical(normalizePath(find.package("shinyAssistantUI")), installed))
      shiny::runApp("tests/verify/agent_checklist_autofollow_app.R",
        host = "127.0.0.1", port = port, launch.browser = FALSE
      )
    },
    args = list(project = project, installed = installed, port = port),
    stdout = stdout, stderr = stderr
  )
  ready <- FALSE
  for (i in seq_len(150L)) {
    if (!app$is_alive()) break
    ready <- any(grepl("Listening on", readLines(stderr, warn = FALSE), fixed = TRUE))
    if (ready) break
    Sys.sleep(0.1)
  }
  if (!ready) stop(paste(readLines(stderr, warn = FALSE), collapse = "\n"), call. = FALSE)
  cat("INSTALL=", installed, " VERSION=", version, "\n", sep = "")
  processx::run("python3", c(
    "tests/verify/verify_agent_checklist_autofollow_installed.py",
    sprintf("http://127.0.0.1:%d/", port), version
  ), timeout = 90, echo = TRUE, error_on_status = TRUE)
  invisible(NULL)
}

main()
