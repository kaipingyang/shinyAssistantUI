# RStudio addin — IDE/editor context & file navigation helpers
# 从 addin.R 拆出（Plan 16 Phase 2，行为不变）：相对路径、在编辑器打开文件、
# 活动编辑器上下文采样、上下文文本拼接。`%||%` 见 handlers.R。

# 绝对路径 → 相对项目根(fixed=TRUE 避免正则/Windows 元字符问题;项目外则保留绝对)。
.rel_path <- function(path, project) {
  if (is.null(path) || !nzchar(path) || is.null(project) || !nzchar(project)) return(path)
  p  <- tryCatch(normalizePath(path, mustWork = FALSE),    error = function(e) path)
  pr <- tryCatch(normalizePath(project, mustWork = FALSE), error = function(e) project)
  pr_slash <- if (endsWith(pr, .Platform$file.sep)) pr else paste0(pr, .Platform$file.sep)
  if (startsWith(p, pr_slash)) substring(p, nchar(pr_slash) + 1L) else p
}

# 活动编辑器上下文:list(path, rel, selection, first_line, last_line) 或 NULL。全程 guard。
# 点击文件引用 / Claude 编辑后揭示 → 在 RStudio 编辑器打开。
# 相对路径按 project 解析成绝对路径；若编辑器已聚焦同一文件则不重复跳转（避免抢焦点）。
.addin_open_file <- function(path, line = NULL, project = NULL) {
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) return(invisible(NULL))
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) return(invisible(NULL))

  abs_path <- path
  if (!isTRUE(startsWith(path, "/")) && !grepl("^[A-Za-z]:", path) && !is.null(project)) {
    abs_path <- file.path(project, path)
  }
  abs_path <- tryCatch(normalizePath(abs_path, winslash = "/", mustWork = FALSE),
                       error = function(e) abs_path)
  if (!file.exists(abs_path)) return(invisible(NULL))

  # 已聚焦同一文件则不跳转
  current <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) NULL)
  if (!is.null(current) && nzchar(current)) {
    current_norm <- tryCatch(normalizePath(current, winslash = "/", mustWork = FALSE),
                             error = function(e) current)
    if (identical(current_norm, abs_path)) return(invisible(NULL))
  }

  ln <- suppressWarnings(as.integer(line))
  if (length(ln) != 1L || is.na(ln) || ln < 1L) ln <- -1L
  tryCatch(rstudioapi::navigateToFile(abs_path, line = ln), error = function(e) NULL)
  invisible(NULL)
}

# 只采样第一段 selection，确保文本与行范围属于同一个选区。
.addin_editor_context <- function(project = NULL) {
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) return(NULL)
  ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
  if (is.null(ctx)) return(NULL)
  path <- tryCatch(ctx$path, error = function(e) "")
  if (is.null(path) || !nzchar(path)) path <- NULL
  ranges <- tryCatch(ctx$selection, error = function(e) NULL)
  sel <- ""; a <- NULL; b <- NULL
  if (length(ranges)) {
    first <- ranges[[1L]]
    sel <- tryCatch(first$text %||% "", error = function(e) "")
    rg <- tryCatch(first$range, error = function(e) NULL)
    if (!is.null(rg)) { a <- tryCatch(rg$start[[1]], error = function(e) NULL)
                        b <- tryCatch(rg$end[[1]],   error = function(e) NULL) }
  }
  if (is.null(path) && !nzchar(sel)) return(NULL)
  list(path = path, rel = if (!is.null(path)) .rel_path(path, project) else NULL,
       selection = if (nzchar(sel)) sel else NULL, first_line = a, last_line = b)
}

# 纯函数:把编辑器上下文拼成要 append 到 Claude Code 预设提示词的文本。
# selection 截断到 ~4000 字符,避免提示词膨胀。
.addin_context_text <- function(ctx, project) {
  lines <- c(paste0("You are assisting a user inside the RStudio IDE.",
                    " Project root (your working directory): ", project, "."))
  if (!is.null(ctx)) {
    if (!is.null(ctx$rel))
      lines <- c(lines, paste0("The user's active editor file is `", ctx$rel, "`."))
    if (!is.null(ctx$selection)) {
      sel <- ctx$selection
      if (nchar(sel) > 4000L) sel <- paste0(substr(sel, 1L, 4000L), "\n... (truncated)")
      loc <- if (!is.null(ctx$first_line) && !is.null(ctx$last_line))
        paste0(" (lines ", ctx$first_line, "-", ctx$last_line, ")") else ""
      lines <- c(lines,
                 paste0("They have selected this code", loc, ":\n```\n", sel, "\n```"))
    }
  }
  lines <- c(lines,
             paste0("Use your file tools (Read/Edit/Bash/Grep) on the project as needed;",
                    " prefer paths relative to the project root."))
  paste(lines, collapse = "\n")
}
