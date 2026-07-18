#' Load Claude Code skills as slash commands
#'
#' Discovers user-invocable Claude Code skills and legacy custom commands for
#' the slash menu. The loader intentionally scans only direct entries in the
#' personal and project configuration roots:
#'
#' * `~/.claude/skills/<skill-name>/SKILL.md`
#' * `~/.claude/commands/<command-name>.md`
#' * `<project_dir>/.claude/skills/<skill-name>/SKILL.md`
#' * `<project_dir>/.claude/commands/<command-name>.md`
#'
#' This mirrors Claude Code's base-session discovery without recursively
#' flattening repositories or plugin copies embedded inside a skill directory.
#' Claude Code discovers nested project `.claude/skills/` directories on demand
#' and advertises those (with directory-qualified names) through Agent SDK
#' server info.
#'
#' Official precedence is applied: within one scope, a skill overrides a legacy
#' command of the same name; personal entries override project entries. Plugin
#' skills are not read from the marketplace cache because that cache includes
#' disabled and duplicate plugins and requires namespacing. Active plugin and
#' bundled skills are supplied by Claude Code through Agent SDK server info.
#'
#' `user-invocable: false` and `skillOverrides: {name: "off"}` entries are
#' omitted. Returned prompts preserve the literal `/name` invocation so Claude
#' Code, rather than this package, performs argument substitution, dynamic
#' context injection, permission grants, and forked-skill execution.
#'
#' @param project_dir Path to the project root. Defaults to [getwd()].
#' @param include_plugins Retained for API compatibility. Plugin marketplace
#'   caches are never scanned directly; active plugin commands come from the
#'   connected Claude Code process.
#'
#' @return A list of command definitions with `name`, `description`, `prompt`,
#'   `category`, `source`, and `kind` fields.
#' @export
load_claude_skills <- function(project_dir = getwd(), include_plugins = TRUE) {
  home <- path.expand(Sys.getenv("HOME", unset = "~"))
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = FALSE)

  parse_frontmatter <- function(content) {
    metadata <- list()
    body_start <- 1L
    if (length(content) > 1L && identical(trimws(content[1L]), "---")) {
      closing <- which(trimws(content[-1L]) == "---")
      if (length(closing)) {
        closing <- closing[1L] + 1L
        lines <- content[seq.int(2L, closing - 1L)]
        i <- 1L
        while (i <= length(lines)) {
          hit <- regexec("^([A-Za-z0-9_-]+):[[:space:]]*(.*)$", lines[i])
          parts <- regmatches(lines[i], hit)[[1L]]
          if (length(parts)) {
            key <- parts[2L]
            value <- parts[3L]
            if (value %in% c(">", "|")) {
              folded <- character()
              i <- i + 1L
              while (i <= length(lines) && grepl("^[[:space:]]+", lines[i])) {
                folded <- c(folded, trimws(lines[i]))
                i <- i + 1L
              }
              value <- if (identical(value, ">")) paste(folded, collapse = " ") else paste(folded, collapse = "\n")
              i <- i - 1L
            }
            value <- sub('^(["\'])(.*)\\1$', "\\2", value)
            if (tolower(value) %in% c("true", "false")) value <- identical(tolower(value), "true")
            metadata[[key]] <- value
          }
          i <- i + 1L
        }
        body_start <- closing + 1L
      }
    }
    body <- if (body_start <= length(content)) content[seq.int(body_start, length(content))] else character()
    list(metadata = metadata, body = body)
  }

  fallback_description <- function(lines) {
    lines <- trimws(lines)
    lines <- lines[nzchar(lines)]
    if (!length(lines)) return("")
    candidate <- sub("^#{1,6}[[:space:]]*", "", lines[1L])
    substr(candidate, 1L, 1536L)
  }

  parse_entry <- function(path, name, source, kind) {
    content <- tryCatch(readLines(path, warn = FALSE, encoding = "UTF-8"),
                        error = function(e) character())
    if (!length(content)) return(NULL)
    parsed <- parse_frontmatter(content)
    metadata <- parsed$metadata
    description <- metadata$description %||% fallback_description(parsed$body)
    if (!is.character(description) || !length(description)) description <- ""
    list(
      name = name,
      description = description[1L],
      prompt = paste0("/", name),
      category = paste(if (identical(source, "personal")) "Personal" else "Project",
                       if (identical(kind, "skill")) "Skills" else "Commands"),
      source = source,
      kind = kind,
      user_invocable = !identical(metadata[["user-invocable"]], FALSE),
      argument_hint = metadata[["argument-hint"]] %||% NULL
    )
  }

  collect_scope <- function(root, source) {
    entries <- list()
    command_dir <- file.path(root, ".claude", "commands")
    if (dir.exists(command_dir)) {
      files <- sort(list.files(command_dir, pattern = "\\.md$", full.names = TRUE,
                               recursive = FALSE))
      for (path in files) {
        name <- tools::file_path_sans_ext(basename(path))
        entries[[name]] <- parse_entry(path, name, source, "command")
      }
    }

    skill_dir <- file.path(root, ".claude", "skills")
    if (dir.exists(skill_dir)) {
      dirs <- sort(list.dirs(skill_dir, full.names = TRUE, recursive = FALSE))
      for (dir in dirs) {
        path <- file.path(dir, "SKILL.md")
        if (!file.exists(path)) next
        name <- basename(dir)
        # Skills override legacy commands in the same scope.
        entries[[name]] <- parse_entry(path, name, source, "skill")
      }
    }
    Filter(Negate(is.null), entries)
  }

  read_overrides <- function(path) {
    if (!file.exists(path) || !requireNamespace("jsonlite", quietly = TRUE)) return(list())
    settings <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                         error = function(e) list())
    settings$skillOverrides %||% list()
  }
  overrides <- list()
  for (path in c(file.path(home, ".claude", "settings.json"),
                 file.path(project_dir, ".claude", "settings.json"),
                 file.path(project_dir, ".claude", "settings.local.json"))) {
    overrides <- utils::modifyList(overrides, read_overrides(path))
  }

  # Project is loaded first; personal overwrites it according to Claude Code's
  # documented precedence (enterprise > personal > project > bundled).
  entries <- collect_scope(project_dir, "project")
  personal <- collect_scope(home, "personal")
  for (name in names(personal)) entries[[name]] <- personal[[name]]

  visible <- Filter(function(entry) {
    state <- overrides[[entry$name]] %||% NULL
    if (identical(state, "off")) return(FALSE)
    if (is.null(state) && !isTRUE(entry$user_invocable)) return(FALSE)
    TRUE
  }, entries)

  result <- lapply(visible, function(entry) {
    state <- overrides[[entry$name]] %||% NULL
    if (identical(state, "name-only")) entry$description <- ""
    entry$user_invocable <- NULL
    entry
  })
  # Stable, source-aware ordering keeps the menu readable.
  if (length(result)) {
    ord <- order(vapply(result, function(x) match(x$source, c("personal", "project")), integer(1)),
                 vapply(result, `[[`, character(1), "name"))
    result <- result[ord]
  }
  unname(result)
}
