#' Load Claude Code skill files as slash commands
#'
#' Scans `.claude/commands/` directories for skill `.md` files and returns
#' a list suitable for the `commands` parameter of [assistantUIServer()].
#'
#' Skill files are loaded from three locations in ascending priority order
#' (higher-priority sources override lower-priority ones with the same name):
#'
#' 1. Plugin marketplace skills:
#'    `~/.claude/plugins/marketplaces/*/plugins/*/commands/*.md`
#' 2. User-global skills: `~/.claude/commands/*.md`
#' 3. Project skills: `<project_dir>/.claude/commands/*.md`
#'
#' Each `.md` file may use YAML frontmatter:
#' ```
#' ---
#' description: One-line description
#' ---
#' Prompt content here…
#' ```
#' Or a simpler format where the first non-empty line is the description and
#' the rest is the prompt.
#'
#' @note Built-in Claude Code CLI commands (`/model`, `/resume`, `/clear`, etc.)
#'   are compiled into the Claude Code binary and cannot be loaded this way.
#'   Only skill files stored as `.md` in `.claude/commands/` directories are
#'   surfaced here.
#'
#' @param project_dir Path to the project root. Defaults to [getwd()].
#' @param include_plugins Logical. If `TRUE` (default), also scan plugin
#'   marketplace directories under `~/.claude/plugins/`.
#'
#' @return A list of command definitions, each a named list with `name`,
#'   `description`, and `prompt` fields, ready to pass to `assistantUIServer`.
#' @export
load_claude_skills <- function(project_dir = getwd(), include_plugins = TRUE) {
  home <- Sys.getenv("HOME")

  # name → file path; higher-priority sources overwrite lower-priority ones
  skill_files <- list()

  # ── 1. Plugin marketplace (lowest priority) ──────────────────────────────
  if (include_plugins) {
    plugin_base <- file.path(home, ".claude", "plugins", "marketplaces")
    if (dir.exists(plugin_base)) {
      all_md <- list.files(plugin_base, pattern = "\\.md$",
                           recursive = TRUE, full.names = TRUE)
      plugin_md <- all_md[grepl("/commands/[^/]+\\.md$", all_md)]
      for (f in plugin_md) {
        nm <- tools::file_path_sans_ext(basename(f))
        if (!nm %in% names(skill_files)) skill_files[[nm]] <- f
      }
    }
  }

  # ── 2. User-global commands ───────────────────────────────────────────────
  global_dir <- file.path(home, ".claude", "commands")
  if (dir.exists(global_dir)) {
    for (f in list.files(global_dir, pattern = "\\.md$", full.names = TRUE)) {
      skill_files[[tools::file_path_sans_ext(basename(f))]] <- f
    }
  }

  # ── 3. Project commands (highest priority) ───────────────────────────────
  project_cmd_dir <- file.path(project_dir, ".claude", "commands")
  if (dir.exists(project_cmd_dir)) {
    for (f in list.files(project_cmd_dir, pattern = "\\.md$", full.names = TRUE)) {
      skill_files[[tools::file_path_sans_ext(basename(f))]] <- f
    }
  }

  # ── Parse files ───────────────────────────────────────────────────────────
  result <- lapply(names(skill_files), function(nm) {
    f       <- skill_files[[nm]]
    content <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    if (length(content) == 0) return(NULL)

    description  <- ""
    prompt_start <- 1L

    # YAML frontmatter
    if (length(content) > 1 && trimws(content[1]) == "---") {
      end_idx <- which(trimws(content[-1]) == "---")
      if (length(end_idx) > 0) {
        end_idx  <- end_idx[1] + 1L
        fm_lines <- content[seq(2, end_idx - 1)]
        desc_hit <- grep("^description:", fm_lines, value = TRUE)
        if (length(desc_hit) > 0) {
          description <- gsub('^["\']|["\']$', "",
                              sub("^description:\\s*", "", desc_hit[1]))
        }
        prompt_start <- end_idx + 1L
      }
    }

    if (prompt_start > length(content)) return(NULL)
    prompt_lines <- content[seq(prompt_start, length(content))]
    prompt       <- trimws(paste(prompt_lines, collapse = "\n"))
    if (!nzchar(prompt)) return(NULL)

    # Fallback description: first non-empty line of prompt (strip leading !)
    if (!nzchar(description)) {
      candidate <- trimws(prompt_lines[nzchar(trimws(prompt_lines))])[1]
      if (!is.na(candidate)) {
        description <- substr(sub("^!", "", candidate), 1, 80)
      }
    }

    list(name = nm, description = description, prompt = prompt)
  })

  Filter(Negate(is.null), result)
}
