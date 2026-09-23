# Addin settings v2. All production writes pass through the field-level CAS
# transaction below; readers never repair malformed bytes implicitly.

.addin_settings_fields <- function() c(
  "autoStartCopilotApi", "defaultPermissionMode", "modeVisibility",
  "composerDensity", "assistantTextSize", "runREnabled",
  "showClaudeEditsInRStudio", "diagnosticsEnabled", "showPerformanceOrb"
)

.addin_settings_defaults <- function() list(
  autoStartCopilotApi = TRUE,
  defaultPermissionMode = "default",
  modeVisibility = list(showBypass = TRUE, showYolo = TRUE),
  composerDensity = "comfortable",
  assistantTextSize = "medium",
  runREnabled = TRUE,
  showClaudeEditsInRStudio = TRUE,
  diagnosticsEnabled = TRUE,
  showPerformanceOrb = TRUE
)

.addin_settings_path <- function(home = Sys.getenv("HOME", unset = "~")) {
  .claude_addin_path("addin_settings.json", home)
}

.settings_safe_integer <- function(value, positive = FALSE) {
  if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
      !is.finite(value) || value != floor(value) ||
      value < (if (positive) 1 else 0) || value > 2^53 - 1) return(NULL)
  as.numeric(value)
}

# A small strict JSON parser is used for this security boundary. jsonlite accepts
# duplicate object keys, so parsing with jsonlite alone cannot classify settings.
.strict_json_parse <- function(text) {
  if (!is.character(text) || length(text) != 1L || is.na(text) ||
      startsWith(text, "\ufeff")) {
    stop("invalid_json", call. = FALSE)
  }
  chars <- strsplit(text, "", fixed = TRUE)[[1L]]
  n <- length(chars); i <- 1L
  ws <- function() while (i <= n && chars[[i]] %in% c(" ", "\t", "\r", "\n")) i <<- i + 1L
  parse_string <- function() {
    if (i > n || chars[[i]] != '"') stop("invalid_json", call. = FALSE)
    start <- i; i <<- i + 1L; escaped <- FALSE
    while (i <= n) {
      ch <- chars[[i]]
      if (!escaped && ch == '"') {
        token <- paste(chars[start:i], collapse = "")
        i <<- i + 1L
        value <- tryCatch(jsonlite::fromJSON(token), error = function(e) NULL)
        if (!is.character(value) || length(value) != 1L || is.na(value))
          stop("invalid_json", call. = FALSE)
        return(value)
      }
      if (!escaped && ch == "\\") escaped <- TRUE else escaped <- FALSE
      if (utf8ToInt(ch)[[1L]] < 32L) stop("invalid_json", call. = FALSE)
      i <<- i + 1L
    }
    stop("invalid_json", call. = FALSE)
  }
  parse_number <- function() {
    start <- i
    while (i <= n && grepl("[0-9eE+.-]", chars[[i]])) i <<- i + 1L
    token <- paste(chars[start:(i - 1L)], collapse = "")
    if (!grepl("^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", token))
      stop("invalid_json", call. = FALSE)
    value <- suppressWarnings(as.numeric(token))
    if (!is.finite(value)) stop("invalid_json", call. = FALSE)
    value
  }
  parse_value <- NULL
  parse_array <- function() {
    i <<- i + 1L; ws(); out <- list()
    if (i <= n && chars[[i]] == "]") { i <<- i + 1L; return(out) }
    repeat {
      out[length(out) + 1L] <- list(parse_value()); ws()
      if (i <= n && chars[[i]] == "]") { i <<- i + 1L; return(out) }
      if (i > n || chars[[i]] != ",") stop("invalid_json", call. = FALSE)
      i <<- i + 1L; ws()
    }
  }
  parse_object <- function() {
    i <<- i + 1L; ws(); out <- list(); keys <- character()
    if (i <= n && chars[[i]] == "}") { i <<- i + 1L; return(out) }
    repeat {
      key <- parse_string()
      if (key %in% keys) stop("duplicate_key", call. = FALSE)
      keys <- c(keys, key); ws()
      if (i > n || chars[[i]] != ":") stop("invalid_json", call. = FALSE)
      i <<- i + 1L; ws(); out[key] <- list(parse_value()); ws()
      if (i <= n && chars[[i]] == "}") { i <<- i + 1L; return(out) }
      if (i > n || chars[[i]] != ",") stop("invalid_json", call. = FALSE)
      i <<- i + 1L; ws()
    }
  }
  parse_value <- function() {
    ws(); if (i > n) stop("invalid_json", call. = FALSE)
    ch <- chars[[i]]
    if (ch == '"') return(parse_string())
    if (ch == "{") return(parse_object())
    if (ch == "[") return(parse_array())
    rest <- paste(chars[i:n], collapse = "")
    literals <- list("true" = TRUE, "false" = FALSE, "null" = NULL)
    for (literal in names(literals)) if (startsWith(rest, literal)) {
      i <<- i + nchar(literal)
      return(literals[[literal]])
    }
    if (grepl("[-0-9]", ch)) return(parse_number())
    stop("invalid_json", call. = FALSE)
  }
  ws(); value <- parse_value(); ws()
  if (i <= n) stop("trailing_json", call. = FALSE)
  value
}

.read_strict_json_file <- function(path, max_bytes = 1024^2) {
  if (is.null(path) || !is.character(path) || length(path) != 1L ||
      is.na(path) || !nzchar(path) || !file.exists(path)) {
    return(list(classification = "missing", value = NULL, bytes = raw()))
  }
  info <- tryCatch(file.info(path), error = function(e) NULL)
  if (is.null(info) || !nrow(info) || is.na(info$size[[1L]]) ||
      info$size[[1L]] > max_bytes || isTRUE(info$isdir[[1L]])) {
    return(list(classification = "malformed", value = NULL, bytes = raw()))
  }
  bytes <- tryCatch({
    con <- file(path, "rb"); on.exit(close(con), add = TRUE)
    readBin(con, "raw", n = info$size[[1L]])
  }, error = function(e) raw())
  if (length(bytes) != info$size[[1L]] || any(bytes == as.raw(0)) ||
      (length(bytes) >= 3L && identical(bytes[1:3], as.raw(c(0xef, 0xbb, 0xbf))))) {
    return(list(classification = "malformed", value = NULL, bytes = bytes))
  }
  text <- tryCatch(rawToChar(bytes), error = function(e) NA_character_)
  valid_utf8 <- !is.na(text) && !is.na(iconv(text, from = "UTF-8", to = "UTF-8", sub = NA))
  value <- if (valid_utf8) tryCatch(.strict_json_parse(text), error = function(e) NULL) else NULL
  if (!is.list(value) || is.null(names(value))) {
    list(classification = "malformed", value = NULL, bytes = bytes)
  } else {
    list(classification = "valid", value = value, bytes = bytes)
  }
}

.addin_setting_value <- function(field, value, invalid_default = TRUE) {
  defaults <- .addin_settings_defaults()
  fallback <- if (identical(field, "diagnosticsEnabled")) FALSE else defaults[[field]]
  scalar_bool <- is.logical(value) && length(value) == 1L && !is.na(value)
  valid <- switch(field,
    autoStartCopilotApi = scalar_bool,
    defaultPermissionMode = is.character(value) && length(value) == 1L &&
      !is.na(value) && value %in% c("default", "plan", "acceptEdits", "bypassPermissions", "askAll", "yolo"),
    modeVisibility = is.list(value) && identical(sort(names(value)), sort(c("showBypass", "showYolo"))) &&
      all(vapply(value, function(x) is.logical(x) && length(x) == 1L && !is.na(x), logical(1))),
    composerDensity = is.character(value) && length(value) == 1L &&
      !is.na(value) && value %in% c("comfortable", "compact"),
    assistantTextSize = is.character(value) && length(value) == 1L &&
      !is.na(value) && value %in% c("small", "compact", "medium", "large"),
    runREnabled = scalar_bool,
    showClaudeEditsInRStudio = scalar_bool,
    diagnosticsEnabled = scalar_bool,
    showPerformanceOrb = scalar_bool,
    FALSE
  )
  if (!isTRUE(valid)) return(if (invalid_default) fallback else NULL)
  if (field == "assistantTextSize" && identical(value, "large")) return("medium")
  if (field == "modeVisibility") return(list(
    showBypass = isTRUE(value$showBypass), showYolo = isTRUE(value$showYolo)
  ))
  value
}

.addin_settings_revision_map <- function(metadata) {
  fields <- .addin_settings_fields()
  zero <- setNames(as.list(rep(0, length(fields))), fields)
  if (is.null(metadata)) return(zero)
  if (!is.list(metadata) || !identical(sort(names(metadata)), c("revisions", "version")) ||
      !identical(.settings_safe_integer(metadata$version), 2) ||
      !is.list(metadata$revisions) || !identical(names(metadata$revisions), fields)) return(NULL)
  values <- lapply(metadata$revisions, .settings_safe_integer)
  if (any(vapply(values, is.null, logical(1)))) return(NULL)
  setNames(values, fields)
}

.read_addin_settings_document <- function(path = .addin_settings_path()) {
  defaults <- .addin_settings_defaults()
  raw <- .read_strict_json_file(path)
  if (raw$classification == "missing") return(list(
    classification = "missing", settings = defaults,
    revisions = setNames(as.list(rep(0, length(.addin_settings_fields()))), .addin_settings_fields()),
    object = list(), bytes = raw$bytes
  ))
  if (raw$classification != "valid") return(list(
    classification = "malformed",
    settings = modifyList(defaults, list(diagnosticsEnabled = FALSE, showPerformanceOrb = TRUE)),
    revisions = NULL, object = NULL, bytes = raw$bytes
  ))
  revisions <- .addin_settings_revision_map(raw$value$`_settingsV2`)
  if (is.null(revisions)) return(list(
    classification = "malformed",
    settings = modifyList(defaults, list(diagnosticsEnabled = FALSE, showPerformanceOrb = TRUE)),
    revisions = NULL, object = NULL, bytes = raw$bytes
  ))
  settings <- defaults
  for (field in .addin_settings_fields()) {
    if (field %in% names(raw$value)) settings[[field]] <- .addin_setting_value(field, raw$value[[field]])
  }
  list(classification = "valid", settings = settings, revisions = revisions,
       object = raw$value, bytes = raw$bytes)
}

.read_addin_settings <- function(path = .addin_settings_path()) {
  .read_addin_settings_document(path)$settings
}

.settings_lock_path <- function(path) file.path(dirname(path), ".settings.lock")
.settings_owner_token <- function() .diagnostics_hex_token()
.settings_acquire_lock <- function(path, now = Sys.time) {
  lock <- .settings_lock_path(path)
  dir.create(dirname(lock), recursive = TRUE, showWarnings = FALSE)
  token <- .settings_owner_token()
  if (!.diagnostics_scalar_character(token)) return(NULL)
  acquired <- dir.create(lock, mode = "0700", showWarnings = FALSE)
  if (!acquired && dir.exists(lock)) {
    owner <- .settings_lock_owner(lock)
    now_seconds <- floor(as.numeric(now()))
    created <- if (is.list(owner)) owner$createdUtc else {
      info <- tryCatch(file.info(lock), error = function(e) NULL)
      if (is.null(info) || is.na(info$mtime[[1L]])) now_seconds else floor(as.numeric(info$mtime[[1L]]))
    }
    old_enough <- is.finite(created) && now_seconds - created > 120
    dead <- if (is.null(owner)) TRUE else .settings_lock_owner_dead(owner)
    if (old_enough && identical(dead, TRUE)) {
      quarantine <- paste0(lock, ".stale-", token)
      if (isTRUE(file.rename(lock, quarantine))) {
        unlink(quarantine, recursive = TRUE, force = TRUE)
        acquired <- dir.create(lock, mode = "0700", showWarnings = FALSE)
      }
    }
  }
  if (!acquired) return(NULL)
  start_token <- .settings_process_start_token()
  if (is.null(start_token)) start_token <- paste0("unsupported-", Sys.getpid())
  owner <- list(
    pid = Sys.getpid(), startToken = start_token,
    createdUtc = floor(as.numeric(now())), token = token
  )
  ok <- tryCatch({
    writeLines(as.character(jsonlite::toJSON(owner, auto_unbox = TRUE)),
               file.path(lock, "owner.json"), useBytes = TRUE)
    Sys.chmod(file.path(lock, "owner.json"), "0600", use_umask = FALSE)
    TRUE
  }, error = function(e) FALSE)
  if (!ok) { unlink(lock, recursive = TRUE, force = TRUE); return(NULL) }
  list(path = lock, token = token)
}
.settings_release_lock <- function(lock) {
  if (!is.list(lock) || !dir.exists(lock$path)) return(invisible(FALSE))
  owner <- .settings_lock_owner(lock$path)
  if (!is.list(owner) || !identical(owner$token, lock$token)) return(invisible(FALSE))
  unlink(lock$path, recursive = TRUE, force = TRUE)
  invisible(!dir.exists(lock$path))
}

.settings_atomic_publish <- function(object, path, lock) {
  if (!is.list(lock) || !dir.exists(lock$path)) return(FALSE)
  owner <- .settings_lock_owner(lock$path)
  if (!is.list(owner) || !identical(owner$token, lock$token)) return(FALSE)
  directory <- dirname(path)
  if (!dir.exists(directory) &&
      !dir.create(directory, recursive = TRUE, mode = "0700")) return(FALSE)
  Sys.chmod(directory, "0700", use_umask = FALSE)
  root <- .native_fs_open_root(directory)
  if (is.null(root)) return(FALSE)
  bytes <- .settings_json_bytes(object)
  if (is.null(bytes)) return(FALSE)
  temporary <- paste0(".", basename(path), ".tmp-", lock$token)
  status <- .native_fs_atomic_replace_at(
    root, temporary, basename(path), bytes
  )
  identical(status, "ok")
}

.settings_process_start_token <- function(pid = Sys.getpid(), proc_root = "/proc") {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid < 1L || .Platform$OS.type != "unix") return(NULL)
  line <- tryCatch(readLines(file.path(proc_root, pid, "stat"), n = 1L, warn = FALSE),
                   error = function(e) character())
  if (length(line) != 1L) return(NULL)
  closing <- regexpr("\\)[^)]*$", line)
  if (closing[[1L]] < 1L) return(NULL)
  tail <- trimws(substr(line, closing[[1L]] + 1L, nchar(line)))
  fields <- strsplit(tail, "[[:space:]]+")[[1L]]
  # tail starts at kernel stat field 3; process starttime is field 22.
  if (length(fields) < 20L || !grepl("^[0-9]+$", fields[[20L]])) return(NULL)
  fields[[20L]]
}

.settings_lock_owner <- function(lock_path) {
  owner_path <- file.path(lock_path, "owner.json")
  parsed <- .read_strict_json_file(owner_path, max_bytes = 4096L)
  owner <- parsed$value
  if (parsed$classification != "valid" || !is.list(owner) ||
      !identical(sort(names(owner)), sort(c("pid", "startToken", "createdUtc", "token"))) ||
      is.null(.settings_safe_integer(owner$pid, TRUE)) ||
      is.null(.settings_safe_integer(owner$createdUtc)) ||
      !.diagnostics_scalar_character(owner$startToken) ||
      !.diagnostics_scalar_character(owner$token)) return(NULL)
  owner
}

.settings_lock_owner_dead <- function(owner) {
  if (!is.list(owner)) return(NA)
  current <- .settings_process_start_token(owner$pid)
  if (is.null(current)) {
    if (.Platform$OS.type == "unix" && dir.exists("/proc")) return(FALSE)
    return(NA)
  }
  !identical(current, owner$startToken)
}

.settings_json_bytes <- function(object) {
  text <- tryCatch(as.character(jsonlite::toJSON(
    object, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA
  )), error = function(error) NULL)
  if (is.null(text)) NULL else charToRaw(paste0(text, "\n"))
}

.transact_addin_settings <- function(ops, path = .addin_settings_path()) {
  result <- function(category, value = NULL, revision = NULL, settings = NULL) list(
    category = category, ok = identical(category, "ok"), value = value,
    revision = revision, settings = settings
  )
  if (!is.list(ops) || !length(ops)) return(result("unsupported"))
  fields <- vapply(ops, function(op) as.character(op$field %||% "")[[1L]], character(1))
  if (anyDuplicated(fields) || any(!fields %in% .addin_settings_fields())) return(result("unsupported"))
  normalized <- vector("list", length(ops))
  for (index in seq_along(ops)) {
    op <- ops[[index]]
    expected <- .settings_safe_integer(op$expected_revision)
    value <- .addin_setting_value(fields[[index]], op$value, invalid_default = FALSE)
    if (is.null(expected) || is.null(value)) return(result("unsupported"))
    normalized[[index]] <- list(field = fields[[index]], expected = expected, value = value)
  }
  lock <- .settings_acquire_lock(path)
  if (is.null(lock)) return(result("busy"))
  on.exit(.settings_release_lock(lock), add = TRUE)
  recovery <- .settings_migration_recover_locked(path, lock)
  if (identical(recovery$category, "migration_recovery_pending"))
    return(result("migration_recovery_pending"))
  doc <- .read_addin_settings_document(path)
  if (doc$classification == "malformed") return(result("malformed_document"))
  object <- if (doc$classification == "missing") list() else doc$object
  revisions <- doc$revisions; settings <- doc$settings
  for (op in normalized) {
    current <- revisions[[op$field]]
    if (!identical(as.numeric(current), as.numeric(op$expected))) {
      return(result("stale_revision", settings[[op$field]], current, settings))
    }
    if (current >= 2^53 - 1) return(result("revision_exhausted", settings[[op$field]], current, settings))
  }
  for (op in normalized) {
    object[[op$field]] <- op$value
    settings[[op$field]] <- op$value
    revisions[[op$field]] <- revisions[[op$field]] + 1
  }
  object$`_settingsV2` <- list(version = 2L, revisions = revisions)
  if (!.settings_atomic_publish(object, path, lock)) return(result("io_error"))
  confirmed <- .read_addin_settings_document(path)
  if (confirmed$classification != "valid") return(result("readback_mismatch"))
  for (op in normalized) {
    if (!identical(confirmed$settings[[op$field]], op$value) ||
        !identical(as.numeric(confirmed$revisions[[op$field]]), revisions[[op$field]])) {
      return(result("readback_mismatch"))
    }
  }
  last <- normalized[[length(normalized)]]
  result("ok", confirmed$settings[[last$field]], confirmed$revisions[[last$field]], confirmed$settings)
}

.transact_addin_setting <- function(field, expected_revision, value,
                                    path = .addin_settings_path()) {
  .transact_addin_settings(list(list(
    field = field, expected_revision = expected_revision, value = value
  )), path)
}

# Compatibility helper: still transactional and never used by production
# callbacks. It applies the supplied recognized fields as one CAS transaction.
.write_addin_settings <- function(settings, path = .addin_settings_path()) {
  if (!is.list(settings)) return(invisible(NULL))
  doc <- .read_addin_settings_document(path)
  if (doc$classification == "malformed") return(invisible(NULL))
  present <- intersect(.addin_settings_fields(), names(settings))
  ops <- lapply(present, function(field) list(
    field = field, expected_revision = doc$revisions[[field]], value = settings[[field]]
  ))
  tx <- .transact_addin_settings(ops, path)
  if (!isTRUE(tx$ok)) return(invisible(NULL))
  invisible(tx$settings)
}

.migrate_addin_settings <- function(home = Sys.getenv("HOME", unset = "~")) {
  path <- .addin_settings_path(home)
  directory <- dirname(path)
  if (!dir.exists(directory) &&
      !dir.create(directory, recursive = TRUE, mode = "0700", showWarnings = FALSE))
    return(invisible(FALSE))
  lock <- .settings_acquire_lock(path)
  if (is.null(lock)) return(invisible(FALSE))
  on.exit(.settings_release_lock(lock), add = TRUE)
  recovery <- .settings_migration_recover_locked(path, lock)
  if (identical(recovery$category, "migration_recovery_pending")) return(invisible(FALSE))
  if (startsWith(recovery$category, "quarantined")) return(invisible(FALSE))
  if (recovery$category %in% c("completed", "completed_with_retained")) return(invisible(TRUE))
  quarantine_pattern <- paste0("^", gsub("\\.", "\\\\.", .settings_migration_journal_basename),
                               "\\.quarantine-[0-9a-f]{32}$")
  if (any(grepl(quarantine_pattern, list.files(directory, all.files = TRUE))))
    return(invisible(FALSE))
  doc <- .read_addin_settings_document(path)
  if (!identical(doc$classification, "missing")) return(invisible(FALSE))
  root_handle <- .native_fs_open_root(directory)
  owner <- .settings_migration_lock_owner(lock)
  migration_id <- .diagnostics_hex_token()
  if (is.null(root_handle) || is.null(owner) || !.diagnostics_scalar_character(migration_id))
    return(invisible(FALSE))
  legacy <- .settings_migration_legacy_paths(home)
  entries <- list()
  for (field in .addin_settings_fields()) {
    if (!field %in% names(legacy)) next
    candidate_path <- unname(legacy[[field]])
    if (!file.exists(candidate_path)) next
    entry <- .settings_migration_capture_entry(root_handle, field, candidate_path)
    if (!is.null(entry)) entries[[length(entries) + 1L]] <- entry
  }
  if (!length(entries)) return(invisible(FALSE))
  candidate <- .settings_migration_candidate(entries)
  candidate_bytes <- .settings_json_bytes(candidate)
  candidate_sha <- .native_sha256(candidate_bytes)
  if (is.null(candidate_sha)) return(invisible(FALSE))
  journal <- list(
    version = 1L, migrationId = migration_id, state = "prepared",
    owner = owner, takeover = NULL, entries = entries,
    candidateSha256 = candidate_sha
  )
  if (!.settings_migration_write_journal(
      directory, root_handle, lock, journal, create = TRUE
    )) return(invisible(FALSE))
  completed <- .settings_migration_recover_locked(path, lock)
  invisible(completed$category %in% c("completed", "completed_with_retained"))
}

.persist_addin_diagnostics_setting <- function(settings_state, value,
                                                path = .addin_settings_path(), ...) {
  if (!is.environment(settings_state) || !.diagnostics_scalar_logical(value)) return(FALSE)
  revisions <- settings_state$revisions %||% .read_addin_settings_document(path)$revisions
  if (is.null(revisions)) return(FALSE)
  tx <- .transact_addin_setting("diagnosticsEnabled", revisions$diagnosticsEnabled, value, path)
  if (!isTRUE(tx$ok)) return(FALSE)
  settings_state$v <- tx$settings
  settings_state$revisions <- .read_addin_settings_document(path)$revisions
  TRUE
}

.capture_addin_launch_contract <- function(settings, revisions,
                                           diagnostics_env = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS", unset = ""),
                                           diagnostics_dir_env = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS_DIR", unset = "")) {
  defaults <- .addin_settings_defaults()
  if (!is.list(settings)) settings <- defaults
  if (!is.list(revisions)) revisions <- setNames(as.list(rep(0, 9)), .addin_settings_fields())
  raw <- trimws(as.character(diagnostics_env %||% "")[[1L]])
  source <- if (nzchar(raw)) "env" else "persisted"
  value <- if (nzchar(raw)) is.list(.diagnostics_launch_from_env(raw, "")) else isTRUE(settings$diagnosticsEnabled)
  list(
    launch_contract_version = 2L,
    captured_addin = list(
      diagnostics = list(present = TRUE, value = value, source = source,
                         revision = revisions$diagnosticsEnabled %||% 0),
      showPerformanceOrb = list(present = TRUE, value = isTRUE(settings$showPerformanceOrb),
                                source = "persisted",
                                revision = revisions$showPerformanceOrb %||% 0)
    ),
    diagnostics_directory = if (value && nzchar(trimws(diagnostics_dir_env)))
      normalizePath(path.expand(trimws(diagnostics_dir_env)), winslash = "/", mustWork = FALSE) else NULL
  )
}

.resolve_addin_launch_contract <- function(contract, diagnostics_override = NULL) {
  exact_field <- function(value, sources) is.list(value) && identical(sort(names(value)),
    sort(c("present", "value", "source", "revision"))) && isTRUE(value$present) &&
    .diagnostics_scalar_logical(value$value) && is.character(value$source) &&
    length(value$source) == 1L && value$source %in% sources &&
    !is.null(.settings_safe_integer(value$revision))
  valid <- is.list(contract) && identical(contract$launch_contract_version, 2L) &&
    is.list(contract$captured_addin) &&
    exact_field(contract$captured_addin$diagnostics, c("persisted", "env")) &&
    exact_field(contract$captured_addin$showPerformanceOrb, "persisted")
  diagnostic_value <- if (valid) isTRUE(contract$captured_addin$diagnostics$value) else FALSE
  if (!is.null(diagnostics_override)) diagnostic_value <- isTRUE(diagnostics_override)
  config <- list(enabled = diagnostic_value)
  if (diagnostic_value && valid && is.character(contract$diagnostics_directory) &&
      length(contract$diagnostics_directory) == 1L && nzchar(contract$diagnostics_directory)) {
    config$directory <- contract$diagnostics_directory
  }
  list(diagnostics = config,
       showPerformanceOrb = if (valid) isTRUE(contract$captured_addin$showPerformanceOrb$value) else TRUE,
       valid = valid)
}

.addin_diagnostics_launch_decision <- function(settings = .read_addin_settings(),
                                               enabled_value = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS", unset = ""),
                                               directory_value = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS_DIR", unset = "")) {
  revisions <- setNames(as.list(rep(0, 9)), .addin_settings_fields())
  contract <- .capture_addin_launch_contract(settings, revisions, enabled_value, directory_value)
  resolved <- .resolve_addin_launch_contract(contract)
  list(config = if (resolved$diagnostics$enabled) resolved$diagnostics else FALSE,
       launch_enabled = resolved$diagnostics$enabled,
       environment_override = if (!nzchar(trimws(enabled_value))) "none" else
         if (resolved$diagnostics$enabled) "on" else "off")
}


.settings_migration_journal_basename <- ".settings-rds-migration-v2.json"
.settings_migration_identity_fields <- c("dev", "ino", "mode", "nlink", "size", "mtime", "ctime")

.settings_migration_legacy_paths <- function(home) c(
  defaultPermissionMode = .claude_addin_path("default_permission_mode.rds", home),
  modeVisibility = .claude_addin_path("mode_visibility.rds", home),
  composerDensity = .claude_addin_path("composer_density.rds", home),
  runREnabled = .claude_addin_path("run_r_enabled.rds", home)
)

.settings_migration_owner_valid <- function(owner) {
  is.list(owner) && identical(names(owner), c("pid", "startToken", "createdUtc", "token")) &&
    !is.null(.settings_safe_integer(owner$pid, TRUE)) &&
    !is.null(.settings_safe_integer(owner$createdUtc)) &&
    .diagnostics_scalar_character(owner$startToken) &&
    .diagnostics_scalar_character(owner$token) && grepl("^[0-9a-f]{32}$", owner$token)
}

.settings_migration_owner_equal <- function(left, right) {
  .settings_migration_owner_valid(left) && .settings_migration_owner_valid(right) &&
    identical(as.numeric(left$pid), as.numeric(right$pid)) &&
    identical(left$startToken, right$startToken) &&
    identical(as.numeric(left$createdUtc), as.numeric(right$createdUtc)) &&
    identical(left$token, right$token)
}

.settings_migration_lock_owner <- function(lock) {
  owner <- if (is.list(lock)) .settings_lock_owner(lock$path) else NULL
  if (!.settings_migration_owner_valid(owner) || !identical(owner$token, lock$token)) NULL else owner
}

.settings_migration_capture_raw <- function(root_handle, basename, max_bytes = 1024^2) {
  handle <- .native_fs_open_read_at(root_handle, basename)
  if (is.null(handle)) return(NULL)
  on.exit(.native_file_close(handle), add = TRUE)
  first <- .native_file_stat(handle)
  path_identity <- .native_fs_stat_at(root_handle, basename)
  fields <- .settings_migration_identity_fields
  root_identity <- .native_file_stat(root_handle)
  uid <- if (is.list(root_identity)) as.numeric(root_identity$uid) else NA_real_
  if (is.null(first) || is.null(path_identity) || !isTRUE(first$regular) ||
      first$nlink != 1 || first$mode != 384L || !is.finite(uid) || first$uid != uid ||
      first$size < 1 || first$size > max_bytes ||
      !identical(first[fields], path_identity[fields])) return(NULL)
  bytes <- .native_file_read_all(handle, max_bytes)
  second <- .native_file_stat(handle)
  if (!is.raw(bytes) || length(bytes) != first$size || is.null(second) ||
      !identical(first[fields], second[fields])) return(NULL)
  list(bytes = bytes, identity = first[fields], sha256 = .native_sha256(bytes))
}

.settings_migration_capture_entry <- function(root_handle, field, path) {
  allowed <- .settings_migration_legacy_paths(dirname(dirname(path)))
  basename <- basename(path)
  if (!field %in% names(allowed) || !identical(basename, basename(allowed[[field]]))) return(NULL)
  first <- .settings_migration_capture_raw(root_handle, basename)
  if (is.null(first) || is.null(first$sha256)) return(NULL)
  value <- tryCatch(readRDS(path), error = function(error) NULL)
  value <- .addin_setting_value(field, value, invalid_default = FALSE)
  second <- .settings_migration_capture_raw(root_handle, basename)
  fields <- .settings_migration_identity_fields
  if (is.null(value) || is.null(second) || !identical(first$identity[fields], second$identity[fields]) ||
      !identical(first$sha256, second$sha256)) return(NULL)
  list(field = field, legacyBasename = basename, identity = first$identity,
       sha256 = first$sha256, value = value, targetRevision = 1)
}

.settings_migration_candidate <- function(entries) {
  object <- .addin_settings_defaults()
  revisions <- setNames(as.list(rep(0, length(.addin_settings_fields()))), .addin_settings_fields())
  for (entry in entries) {
    object[[entry$field]] <- entry$value
    revisions[[entry$field]] <- 1
  }
  object$`_settingsV2` <- list(version = 2L, revisions = revisions)
  object
}

.settings_migration_journal_valid <- function(value) {
  top <- c("version", "migrationId", "state", "owner", "takeover", "entries", "candidateSha256")
  if (!is.list(value) || !identical(names(value), top) ||
      is.null(.settings_safe_integer(value$version)) || value$version != 1 ||
      !.diagnostics_scalar_character(value$migrationId) || !grepl("^[0-9a-f]{32}$", value$migrationId) ||
      !value$state %in% c("prepared", "published") ||
      !.settings_migration_owner_valid(value$owner) || !is.list(value$entries) ||
      !.diagnostics_scalar_character(value$candidateSha256) ||
      !grepl("^[0-9a-f]{64}$", value$candidateSha256)) return(FALSE)
  if (!is.null(value$takeover)) {
    if (!is.list(value$takeover) ||
        !identical(names(value$takeover), c("previousOwner", "takenOverUtc", "count")) ||
        !.settings_migration_owner_valid(value$takeover$previousOwner) ||
        is.null(.settings_safe_integer(value$takeover$takenOverUtc)) ||
        is.null(.settings_safe_integer(value$takeover$count, TRUE))) return(FALSE)
  }
  expected_order <- .addin_settings_fields()
  observed <- character()
  for (entry in value$entries) {
    if (!is.list(entry) || !identical(names(entry), c(
      "field", "legacyBasename", "identity", "sha256", "value", "targetRevision"
    )) || !.diagnostics_scalar_character(entry$field) ||
        !entry$field %in% names(.settings_migration_legacy_paths("~")) ||
        !.diagnostics_scalar_character(entry$legacyBasename) ||
        !identical(entry$legacyBasename, basename(.settings_migration_legacy_paths("~")[[entry$field]])) ||
        !is.list(entry$identity) || !identical(names(entry$identity), .settings_migration_identity_fields) ||
        any(vapply(entry$identity, function(item) is.null(.settings_safe_integer(item)), logical(1))) ||
        !.diagnostics_scalar_character(entry$sha256) || !grepl("^[0-9a-f]{64}$", entry$sha256) ||
        is.null(.addin_setting_value(entry$field, entry$value, invalid_default = FALSE)) ||
        !identical(entry$targetRevision, 1)) return(FALSE)
    observed <- c(observed, entry$field)
  }
  !anyDuplicated(observed) && identical(observed, expected_order[expected_order %in% observed])
}

.settings_migration_read_journal <- function(directory, root_handle) {
  basename <- .settings_migration_journal_basename
  path <- file.path(directory, basename)
  if (!file.exists(path)) return(list(classification = "missing", value = NULL, identity = NULL, bytes = raw()))
  captured <- .settings_migration_capture_raw(root_handle, basename)
  if (is.null(captured)) return(list(classification = "unsafe", value = NULL, identity = NULL, bytes = raw()))
  text <- tryCatch(rawToChar(captured$bytes), error = function(error) NULL)
  value <- if (!is.null(text) && !is.na(iconv(text, "UTF-8", "UTF-8", sub = NA)) &&
      identical(tail(captured$bytes, 1L), charToRaw("\n"))) tryCatch(
        .strict_json_parse(substr(text, 1L, nchar(text, type = "chars") - 1L)),
        error = function(error) NULL
      ) else NULL
  list(classification = if (.settings_migration_journal_valid(value)) "valid" else "malformed",
       value = value, identity = captured$identity, bytes = captured$bytes)
}

.settings_migration_write_journal <- function(directory, root_handle, lock, journal, create = FALSE) {
  owner <- .settings_migration_lock_owner(lock)
  if (is.null(owner) || !.settings_migration_owner_equal(journal$owner, owner) ||
      !.settings_migration_journal_valid(journal)) return(FALSE)
  bytes <- .settings_json_bytes(journal)
  if (is.null(bytes)) return(FALSE)
  temporary <- paste0(".", .settings_migration_journal_basename, ".tmp-", journal$migrationId)
  status <- if (isTRUE(create)) .native_fs_atomic_write_at(
    root_handle, temporary, .settings_migration_journal_basename, bytes
  ) else .native_fs_atomic_replace_at(
    root_handle, temporary, .settings_migration_journal_basename, bytes
  )
  if (!identical(status, "ok")) return(FALSE)
  confirmed <- .settings_migration_read_journal(directory, root_handle)
  identical(confirmed$classification, "valid") && identical(confirmed$bytes, bytes) &&
    .settings_migration_owner_equal(confirmed$value$owner, owner)
}

.settings_migration_quarantine <- function(directory, root_handle, journal_read) {
  identity <- journal_read$identity
  token <- .diagnostics_hex_token()
  if (is.null(identity) || !.diagnostics_scalar_character(token)) return(FALSE)
  identical(.native_fs_quarantine_at(
    root_handle, .settings_migration_journal_basename,
    paste0(.settings_migration_journal_basename, ".quarantine-", token), identity
  ), "ok")
}

.settings_migration_owner_status <- function(owner, probe = .native_process_probe) {
  if (!.settings_migration_owner_valid(owner)) return("unknown")
  first <- tryCatch(probe(owner$pid), error = function(error) list(category = "unknown"))
  second <- tryCatch(probe(owner$pid), error = function(error) list(category = "unknown"))
  if (identical(first$category, "dead") && identical(second$category, "dead")) return("dead")
  live_tokens <- c(
    if (identical(first$category, "live")) first$startToken else character(),
    if (identical(second$category, "live")) second$startToken else character()
  )
  if (length(live_tokens) && any(live_tokens != owner$startToken)) return("reused")
  if (length(live_tokens) == 2L && all(live_tokens == owner$startToken)) return("live")
  "unknown"
}

.settings_migration_entry_matches <- function(root_handle, directory, entry) {
  path <- file.path(directory, entry$legacyBasename)
  if (!file.exists(path)) return("missing")
  current <- .settings_migration_capture_entry(root_handle, entry$field, path)
  fields <- .settings_migration_identity_fields
  if (is.null(current) || !.settings_migration_identity_equal(
      current$identity, entry$identity
    ) ||
      !identical(current$sha256, entry$sha256) || !identical(current$value, entry$value)) "changed" else "matching"
}

.settings_migration_recover_locked <- function(path, lock, probe = .native_process_probe,
                                                now = Sys.time) {
  directory <- dirname(path); root_handle <- .native_fs_open_root(directory)
  if (is.null(root_handle)) return(list(category = "migration_recovery_pending"))
  read <- .settings_migration_read_journal(directory, root_handle)
  if (identical(read$classification, "missing")) return(list(category = "none"))
  if (!identical(read$classification, "valid")) {
    return(list(category = if (.settings_migration_quarantine(directory, root_handle, read))
      "quarantined" else "migration_recovery_pending"))
  }
  journal <- read$value; current_owner <- .settings_migration_lock_owner(lock)
  if (is.null(current_owner)) return(list(category = "migration_recovery_pending"))
  if (!.settings_migration_owner_equal(journal$owner, current_owner)) {
    owner_status <- .settings_migration_owner_status(journal$owner, probe)
    if (identical(owner_status, "live")) return(list(category = "migration_recovery_pending"))
    if (!identical(owner_status, "dead")) {
      return(list(category = if (.settings_migration_quarantine(directory, root_handle, read))
        paste0("quarantined_", owner_status) else "migration_recovery_pending"))
    }
    previous <- journal$owner
    count <- if (is.null(journal$takeover)) 1 else journal$takeover$count + 1
    if (count > 2^53 - 1) return(list(category = "migration_recovery_pending"))
    journal$owner <- current_owner
    journal$takeover <- list(previousOwner = previous,
                             takenOverUtc = floor(as.numeric(now())), count = count)
    if (!.settings_migration_write_journal(directory, root_handle, lock, journal, create = FALSE))
      return(list(category = "migration_recovery_pending"))
  }
  candidate <- .settings_migration_candidate(journal$entries)
  candidate_bytes <- .settings_json_bytes(candidate)
  if (is.null(candidate_bytes) || !identical(.native_sha256(candidate_bytes), journal$candidateSha256)) {
    reread <- .settings_migration_read_journal(directory, root_handle)
    return(list(category = if (.settings_migration_quarantine(directory, root_handle, reread))
      "quarantined" else "migration_recovery_pending"))
  }
  document <- .read_addin_settings_document(path)
  if (identical(document$classification, "missing") && identical(journal$state, "prepared")) {
    matches <- vapply(journal$entries, function(entry)
      identical(.settings_migration_entry_matches(root_handle, directory, entry), "matching"), logical(1))
    if (!all(matches)) {
      reread <- .settings_migration_read_journal(directory, root_handle)
      return(list(category = if (.settings_migration_quarantine(directory, root_handle, reread))
        "quarantined" else "migration_recovery_pending"))
    }
    if (!.settings_atomic_publish(candidate, path, lock))
      return(list(category = "migration_recovery_pending"))
    document <- .read_addin_settings_document(path)
  }
  exact_candidate <- identical(document$classification, "valid") &&
    identical(.native_sha256(document$bytes), journal$candidateSha256)
  if (!exact_candidate) {
    reread <- .settings_migration_read_journal(directory, root_handle)
    return(list(category = if (.settings_migration_quarantine(directory, root_handle, reread))
      "quarantined" else "migration_recovery_pending"))
  }
  for (entry in journal$entries) {
    if (!identical(document$settings[[entry$field]], entry$value) ||
        !identical(as.numeric(document$revisions[[entry$field]]), as.numeric(entry$targetRevision)))
      return(list(category = "migration_recovery_pending"))
  }
  if (identical(journal$state, "prepared")) {
    journal$state <- "published"
    if (!.settings_migration_write_journal(directory, root_handle, lock, journal, create = FALSE))
      return(list(category = "migration_recovery_pending"))
  }
  retained <- 0L
  for (entry in journal$entries) {
    match <- .settings_migration_entry_matches(root_handle, directory, entry)
    if (identical(match, "matching")) {
      current <- .settings_migration_capture_entry(
        root_handle, entry$field, file.path(directory, entry$legacyBasename)
      )
      removed <- !is.null(current) && identical(.native_fs_remove_at(
        root_handle, entry$legacyBasename,
        paste0(".settings-rds-migrated-", journal$migrationId, "-", retained),
        current$identity
      ), "ok")
      if (!removed) retained <- retained + 1L
    } else if (!identical(match, "missing")) retained <- retained + 1L
  }
  final_read <- .settings_migration_read_journal(directory, root_handle)
  if (!identical(final_read$classification, "valid") || !identical(.native_fs_remove_at(
      root_handle, .settings_migration_journal_basename,
      paste0(".settings-rds-journal-done-", journal$migrationId), final_read$identity
    ), "ok")) return(list(category = "migration_recovery_pending"))
  .native_fs_fsync_root(root_handle)
  list(category = if (retained) "completed_with_retained" else "completed",
       retained = retained)
}

.settings_migration_identity_equal <- function(left, right) {
  fields <- .settings_migration_identity_fields
  is.list(left) && is.list(right) && all(fields %in% names(left)) &&
    all(fields %in% names(right)) && all(vapply(fields, function(field) {
      a <- .settings_safe_integer(left[[field]])
      b <- .settings_safe_integer(right[[field]])
      !is.null(a) && !is.null(b) && identical(as.numeric(a), as.numeric(b))
    }, logical(1)))
}
