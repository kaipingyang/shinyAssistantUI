# ── addin UI 偏好持久化(Plan 46)────────────────────────────────────────────
# 4 个用户偏好合并到单个 ~/.claude_addin/addin_settings.json(可读、可手改)。
# 名字 addin_settings 以和 Claude Code 的 ~/.claude/settings.json 消歧义。
# 数据文件(session_map/archived/... /tool_decisions)仍是 RDS。`%||%` 见 handlers.R。

.addin_settings_defaults <- function() {
  list(
    defaultPermissionMode = "default",
    modeVisibility        = list(showBypass = TRUE, showYolo = TRUE),
    composerDensity       = "comfortable",
    runREnabled           = TRUE,
    autoStartCopilotApi   = TRUE
  )
}

.addin_settings_path <- function(home = Sys.getenv("HOME", unset = "~")) {
  .claude_addin_path("addin_settings.json", home)
}

# 读:缺文件/坏 JSON/缺字段 → 用默认兜底;逐字段强制类型,防手改出错。
.read_addin_settings <- function(path = .addin_settings_path()) {
  d <- .addin_settings_defaults()
  raw <- if (!is.null(path) && nzchar(path %||% "") && file.exists(path))
    tryCatch(jsonlite::fromJSON(path, simplifyVector = TRUE), error = function(e) NULL) else NULL
  if (!is.list(raw)) return(d)
  dpm <- raw$defaultPermissionMode
  if (is.character(dpm) && length(dpm) >= 1L && nzchar(dpm[[1L]])) d$defaultPermissionMode <- dpm[[1L]]
  mv <- raw$modeVisibility
  if (is.list(mv)) d$modeVisibility <- list(
    showBypass = if (is.null(mv$showBypass)) TRUE else isTRUE(mv$showBypass),
    showYolo   = if (is.null(mv$showYolo))   TRUE else isTRUE(mv$showYolo)
  )
  cd <- raw$composerDensity
  if (is.character(cd) && length(cd) >= 1L && cd[[1L]] %in% c("comfortable", "compact")) d$composerDensity <- cd[[1L]]
  if (!is.null(raw$runREnabled)) d$runREnabled <- isTRUE(raw$runREnabled)
  if (!is.null(raw$autoStartCopilotApi))
    d$autoStartCopilotApi <- isTRUE(raw$autoStartCopilotApi)
  d
}

# 写:原子(temp + rename)+ auto_unbox(标量不成数组)+ pretty(可手改)+ 末尾换行。
.write_addin_settings <- function(settings, path = .addin_settings_path()) {
  if (is.null(path) || !nzchar(path %||% "")) return(invisible(NULL))
  directory <- dirname(path)
  if (!dir.exists(directory)) dir.create(directory, recursive = TRUE)
  txt <- tryCatch(jsonlite::toJSON(settings, auto_unbox = TRUE, pretty = TRUE),
                  error = function(e) NULL)
  if (is.null(txt)) return(invisible(NULL))
  tmp <- paste0(path, ".tmp-", Sys.getpid(), "-", sample.int(.Machine$integer.max, 1L))
  on.exit(unlink(tmp), add = TRUE)
  writeLines(as.character(txt), tmp)
  if (!file.rename(tmp, path)) stop("Could not atomically write ", path, call. = FALSE)
  invisible(settings)
}

# rds → json 一次性迁移(老用户无感):json 不存在但任一旧偏好 rds 存在 → 读拼写入 → 删旧 rds。
.migrate_addin_settings <- function(home = Sys.getenv("HOME", unset = "~")) {
  path <- .addin_settings_path(home)
  if (file.exists(path)) return(invisible(FALSE))
  olds <- c(
    defaultPermissionMode = .claude_addin_path("default_permission_mode.rds", home),
    composerDensity       = .claude_addin_path("composer_density.rds", home),
    runREnabled           = .claude_addin_path("run_r_enabled.rds", home),
    modeVisibility        = .claude_addin_path("mode_visibility.rds", home)
  )
  if (!any(vapply(olds, file.exists, logical(1)))) return(invisible(FALSE))
  rd <- function(p) if (file.exists(p)) tryCatch(readRDS(p), error = function(e) NULL) else NULL
  s <- .addin_settings_defaults()
  v <- rd(olds[["defaultPermissionMode"]]); if (is.character(v) && length(v) == 1L && nzchar(v)) s$defaultPermissionMode <- v
  v <- rd(olds[["composerDensity"]]); if (is.character(v) && length(v) == 1L && v %in% c("comfortable", "compact")) s$composerDensity <- v
  v <- rd(olds[["runREnabled"]]); if (is.logical(v) && length(v) == 1L && !is.na(v)) s$runREnabled <- v
  v <- rd(olds[["modeVisibility"]]); if (is.list(v)) s$modeVisibility <- list(showBypass = isTRUE(v$showBypass), showYolo = isTRUE(v$showYolo))
  .write_addin_settings(s, path)
  for (p in olds) tryCatch(unlink(p), error = function(e) NULL)
  invisible(TRUE)
}
