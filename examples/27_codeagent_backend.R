# examples/27_codeagent_backend.R
# ─────────────────────────────────────────────────────────────────────────────
# codeagent capability showcase for shinyAssistantUI.
#
# Profiles (choose before launch):
#   CODEAGENT_DEMO_PROFILE=workbench  # default: live streaming + images + rich tools
#   CODEAGENT_DEMO_PROFILE=shield     # Data Shield: hold, scan, then release
#
# Both profiles demonstrate codeagent's real harness through
# make_codeagent_handler():
#   * multi-turn agent loop, thinking, Stop, warmup, and context/cost usage
#   * built-in R/file/search/web/task tools with in-chat Approve/Deny
#   * typed tool output: inline plots/images and table/code/diff artifacts
#   * text/file attachments; workbench also supports one or more images
#   * project/personal skills and configured MCP tools through codeagent
#
# The shield profile additionally registers an in-memory synthetic dataset. It
# buffers the whole model response on the R server and only releases text after
# DataShield$scan_response(). Raw tool arguments and rich display payloads are
# not sent to the browser. Image input is intentionally disabled in this profile
# because codeagent's optional OCR scanner is not fail-closed when OCR is absent.
#
# The per-session scratch directory is only the agent's DEFAULT working directory;
# it is not described as an OS sandbox. Permission prompts remain the execution
# safety boundary. Each Shiny session receives its own handler/client registry,
# scratch directory, and (shield profile) non-cloneable DataShield instance.
#
# Prerequisites: codeagent + ellmer, and OPENAI_BASE_URL / OPENAI_MODEL /
# OPENAI_API_KEY in the project .Renviron or process environment.
#
# Run:
#   shiny::runApp("examples/27_codeagent_backend.R")
#   Sys.setenv(CODEAGENT_DEMO_PROFILE = "shield"); shiny::runApp(...)
# ─────────────────────────────────────────────────────────────────────────────
library(shiny)
library(ellmer)
library(codeagent)
library(shinyAssistantUI)

readRenviron(here::here(".Renviron"))

profile <- tolower(Sys.getenv("CODEAGENT_DEMO_PROFILE", "workbench"))
if (!profile %in% c("workbench", "shield")) {
  stop("CODEAGENT_DEMO_PROFILE must be 'workbench' or 'shield'.", call. = FALSE)
}
permission_mode <- Sys.getenv("CODEAGENT_PERMISSION_MODE", "default")
context_window <- suppressWarnings(as.integer(
  Sys.getenv("CODEAGENT_CONTEXT_WINDOW", "200000")
))
if (is.na(context_window) || context_window <= 0L) context_window <- 200000L

seed_demo_workspace <- function(path) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "# codeagent demo workspace",
    "",
    "This disposable workspace demonstrates reading, editing, R execution,",
    "verification, skills, and permission approvals."
  ), file.path(path, "README.md"))
  writeLines(c(
    "demo_summary <- function() {",
    "  aggregate(mpg ~ cyl, mtcars, mean)",
    "}"
  ), file.path(path, "analysis.R"))

  # A tiny project skill lets the demo show real codeagent skill discovery
  # without installing or modifying anything in the user's HOME directory.
  skill_dir <- file.path(path, ".claude", "skills", "demo-audit")
  dir.create(skill_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "---",
    "name: demo-audit",
    "description: Review the disposable demo workspace and propose safe checks.",
    "---",
    "Read README.md and analysis.R, summarize risks, and suggest verification.",
    "Do not modify files unless the user explicitly asks."
  ), file.path(skill_dir, "SKILL.md"))
}

new_demo_shield <- function() {
  shield <- codeagent::DataShield$new(
    max_rows = 0L,
    distributions = "off",
    k_anon = 5L
  )
  protected_demo <- data.frame(
    subject_id = sprintf("SUBJ-DEMO-%04d", seq_len(12L)),
    site = rep(c("North", "South", "West"), each = 4L),
    treatment = rep(c("A", "B"), 6L),
    age = c(41L, 52L, 37L, 63L, 46L, 58L, 49L, 55L, 44L, 61L, 39L, 53L),
    outcome = c(8.1, 7.4, 9.0, 6.8, 8.7, 7.1, 8.4, 7.8, 9.2, 6.9, 8.8, 7.5),
    stringsAsFactors = FALSE
  )
  shield$register_data(
    protected_demo,
    name = "protected_trial_demo",
    sensitivity = c(
      subject_id = "identifier",
      site = "quasi",
      treatment = "open",
      age = "measure",
      outcome = "measure"
    )
  )
  shield
}

workbench_suggestions <- list(
  list(
    text = "Inspect the workspace",
    prompt = paste(
      "Inspect README.md and analysis.R. Explain the project, then run a focused",
      "verification without changing files."
    )
  ),
  list(
    text = "Analyze mtcars",
    prompt = paste(
      "Use R to summarize mtcars mpg by cylinder, return a compact table, then",
      "explain the strongest pattern."
    )
  ),
  list(
    text = "Create a plot",
    prompt = paste(
      "Use R to plot mtcars horsepower versus mpg, color by cylinder, and show",
      "the resulting chart inline."
    )
  ),
  list(
    text = "Try an approval",
    prompt = paste(
      "Create report.md with a short verified summary of this demo workspace.",
      "Show your plan before requesting permission to write."
    )
  )
)

shield_suggestions <- list(
  list(
    text = "Describe protected schema",
    prompt = paste(
      "Use DescribeData to explain the schema and protection policy for",
      "protected_trial_demo. Do not request or reveal raw rows."
    )
  ),
  list(
    text = "Safe aggregate",
    prompt = paste(
      "Analyze protected_trial_demo only through allowed aggregate tools. Compare",
      "mean outcome by treatment without showing subject-level values."
    )
  ),
  list(
    text = "Test response protection",
    prompt = paste(
      "Explain how Data Shield protects prompt, tool, and response boundaries in",
      "this session. Do not include raw identifiers."
    )
  ),
  list(
    text = "Review audit approach",
    prompt = paste(
      "Describe which non-sensitive checks should be reviewed after protected",
      "analysis. Do not print audit reasons or matched values."
    )
  )
)

# These are prompt macros, not claims that codeagent implements Claude CLI slash
# actions. Native codeagent skills and configured MCP tools remain model tools.
demo_commands <- list(
  list(
    name = "inspect",
    description = "Inspect the demo workspace read-only",
    prompt = "Inspect the demo workspace read-only and summarize its structure."
  ),
  list(
    name = "analyze",
    description = "Plan and run a focused R analysis",
    prompt = "Plan and run a focused R analysis, then explain and verify the result."
  ),
  list(
    name = "verify",
    description = "Run the smallest relevant verification",
    prompt = "Run the smallest relevant verification and report concrete evidence."
  ),
  list(
    name = "explain",
    description = "Explain tools, skills, MCP, permissions, and limits",
    prompt = paste(
      "Explain the codeagent capabilities active in this session: tools, project",
      "skills, configured MCP servers, permissions, usage, and current limits."
    )
  )
)

demo_tools <- list(
  list(name = "Read / Glob / Grep / LS", description = "Read-only workspace exploration"),
  list(name = "RunR / ExploreData", description = "R analysis, tables, and inline plots"),
  list(name = "Write / Edit / Bash", description = "Mutations gated by permission policy"),
  list(name = "WebFetch / WebSearch", description = "Network tools when provider/config permits"),
  list(name = "Task / Agent / Team", description = "Delegation tools supplied by codeagent"),
  list(name = "Skills / MCP", description = "Discovered skills and configured MCP tools")
)

welcome <- paste(
  if (identical(profile, "shield")) {
    paste(
      "Data Shield profile is active. Responses are held on the R server, scanned,",
      "and released once safe; image input is disabled."
    )
  } else {
    paste(
      "Workbench profile is active. Try R plots, image attachments, workspace",
      "inspection, web tools, skills, and an approved file edit."
    )
  },
  "Use /explain for an honest inventory of configured capabilities."
)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = paste("codeagent", profile, "showcase")
)

server <- function(input, output, session) {
  token <- session$token
  if (is.null(token) || !nzchar(token)) token <- "session"
  token <- gsub("[^A-Za-z0-9_-]", "-", token)
  scratch <- file.path(tempdir(), paste0("codeagent-demo-", token))
  seed_demo_workspace(scratch)

  client_factory <- function() {
    chat <- chat_openai_compatible(
      base_url = Sys.getenv("OPENAI_BASE_URL"),
      model = Sys.getenv("OPENAI_MODEL"),
      credentials = function() Sys.getenv("OPENAI_API_KEY")
    )
    shield <- NULL
    if (identical(profile, "shield")) shield <- new_demo_shield()
    codeagent::codeagent_client(
      chat = chat,
      register_tools = TRUE,
      permission_mode = permission_mode,
      cwd = scratch,
      data_shield = shield
    )
  }

  # Handler construction belongs inside server(): its thread/client registry and
  # DataShield lifecycle must never be shared by independent Shiny sessions.
  handler <- make_codeagent_handler(
    client_factory = client_factory,
    permission_mode = permission_mode
  )

  assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "client",
    prewarm = TRUE,
    warming_label = "Starting codeagent\u2026",
    welcome_message = welcome,
    suggestions = if (identical(profile, "shield")) shield_suggestions else workbench_suggestions,
    commands = demo_commands,
    tools = demo_tools,
    show_usage = TRUE,
    context_window = context_window,
    usage_style = "ring",
    working_dir = scratch
  )

  session$onSessionEnded(function() {
    unlink(scratch, recursive = TRUE, force = TRUE)
  })
}

shinyApp(ui, server)
