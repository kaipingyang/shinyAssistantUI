#!/usr/bin/env Rscript
# Plan 167 live check: does the UI-first guidance make the real Claude CLI ask via
# AskUserQuestion / AskUserForm? The form endpoint cancels every request; tools are
# never executed. Usage: Rscript tests/verify/probe_ui_first_prompt.R <outdir>
suppressPackageStartupMessages({ library(jsonlite) })
devtools::load_all(".", quiet = TRUE)
out_dir <- commandArgs(TRUE)[1]
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

form_url <- paste0("ipc://", tempfile("probe-form-", fileext = ".sock"))
endpoint <- callr::r_bg(function(url, project) {
  devtools::load_all(project, quiet = TRUE)
  svc <- list(request = function(req, respond) {
    respond(list(request_id = req$request_id, status = "cancelled", reason = "user"))
  }, close = function() NULL)
  .start_run_r_review_server(url, svc)
  repeat later::run_now(0.1)
}, args = list(url = form_url, project = normalizePath(".")))
on.exit(endpoint$kill_tree(), add = TRUE)
Sys.sleep(3)

cfg <- .addin_ask_form_server(form_url)
cfg$env$CLAUDE_ADDIN_THREAD_ID <- "probe"
mcp_file <- tempfile(fileext = ".json")
writeLines(as.character(toJSON(list(mcpServers = list(ui = cfg)), auto_unbox = TRUE)), mcp_file)

prompts <- c(
  regression = paste(
    "I want to fit a regression on the mtcars data in R but I haven't decided the",
    "outcome, the predictors, whether to log-transform, or the significance level.",
    "Get what you need from me before writing any code."),
  plotting = paste(
    "For my report, should I use ggplot2, base graphics, or plotly? Recommend one but",
    "let me decide before you write anything.")
)
base <- .addin_context_text(NULL, "/tmp/probe-project")
arms <- list(
  baseline = base,
  ui_first = paste0(base, "\n\n", .addin_ui_first_guidance(TRUE))
)

rows <- list()
for (arm in names(arms)) for (case in names(prompts)) {
  log <- file.path(out_dir, paste0(arm, "-", case, ".jsonl"))
  res <- processx::run("claude", c(
    "-p", prompts[[case]], "--output-format", "stream-json", "--verbose",
    "--mcp-config", mcp_file, "--strict-mcp-config",
    "--append-system-prompt", arms[[arm]],
    "--allowedTools", "mcp__ui__AskUserForm",
    "--disallowedTools", "Bash,Write,Edit,NotebookEdit",
    "--max-turns", "3"
  ), wd = tempdir(), timeout = 240, error_on_status = FALSE)
  writeLines(res$stdout, log)
  events <- lapply(strsplit(res$stdout, "\n")[[1]], function(l) tryCatch(fromJSON(l, simplifyVector = FALSE), error = function(e) NULL))
  tools <- unlist(lapply(Filter(function(e) identical(e$type, "assistant"), events), function(e) {
    vapply(Filter(function(b) identical(b$type, "tool_use"), e$message$content), `[[`, "", "name")
  }))
  rows[[length(rows) + 1L]] <- data.frame(arm = arm, case = case,
    tools = if (length(tools)) paste(unique(tools), collapse = ",") else "(none)",
    asked_via_ui = any(tools %in% c("AskUserQuestion", "mcp__ui__AskUserForm")))
}
result <- do.call(rbind, rows)
print(result, row.names = FALSE)
write.csv(result, file.path(out_dir, "summary.csv"), row.names = FALSE)
