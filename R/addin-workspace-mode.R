.canonical_workspace_project <- function(project) {
  if (is.null(project) || !length(project)) return(NULL)
  project <- as.character(project[[1L]])
  if (is.na(project) || !nzchar(project)) return(NULL)
  normalizePath(path.expand(project), winslash = "/", mustWork = FALSE)
}

.canonical_workspace_projects <- function(projects) {
  projects <- unlist(projects, use.names = FALSE)
  if (!length(projects)) return(character())
  normalized <- vapply(
    projects,
    function(project) .canonical_workspace_project(project) %||% "",
    character(1)
  )
  unique(normalized[nzchar(normalized)])
}

.call_compatible_callback <- function(callback, args) {
  if (!is.function(callback)) return(NULL)
  callback_formals <- formals(callback)
  if (is.null(callback_formals)) {
    return(do.call(callback, if (is.primitive(callback)) args else list()))
  }

  params <- names(callback_formals)
  named_params <- setdiff(params, "...")
  arg_names <- names(args) %||% rep("", length(args))
  used <- rep(FALSE, length(args))
  call_args <- list()

  # New protocol fields are injected by exact name first. Remaining legacy
  # formals receive the still-unused argument prefix by position, preserving
  # callbacks such as function(id, value) and function(p, l = NULL).
  for (param in named_params) {
    exact <- which(!used & nzchar(arg_names) & arg_names == param)
    if (length(exact)) {
      index <- exact[[1L]]
      call_args[[param]] <- args[[index]]
      used[[index]] <- TRUE
    }
  }
  for (param in named_params) {
    if (param %in% names(call_args)) next
    index <- which(!used)
    if (!length(index)) next
    index <- index[[1L]]
    call_args[[param]] <- args[[index]]
    used[[index]] <- TRUE
  }
  if ("..." %in% params && any(!used)) {
    call_args <- c(call_args, args[!used])
  }
  do.call(callback, call_args)
}

.call_thread_provider <- function(provider, thread_id = NULL, project = NULL, ...) {
  .call_compatible_callback(
    provider,
    c(list(thread_id = thread_id, project = project), list(...))
  )
}

.workspace_project_label <- function(project) {
  label <- basename(project)
  if (!nzchar(label) || identical(label, ".")) project else label
}

.new_workspace_project_router <- function(projects, initial = NULL) {
  state <- new.env(parent = emptyenv())
  state$projects <- .canonical_workspace_projects(c(initial, projects))
  initial <- .canonical_workspace_project(initial)
  if (is.null(initial) && length(state$projects)) initial <- state$projects[[1L]]
  if (!is.null(initial) && !initial %in% state$projects) {
    state$projects <- c(initial, state$projects)
  }
  state$current <- initial
  state$bindings <- new.env(parent = emptyenv())

  add <- function(project) {
    project <- .canonical_workspace_project(project)
    if (is.null(project)) return(NULL)
    if (!project %in% state$projects) state$projects <- c(state$projects, project)
    project
  }

  bind <- function(thread_id, project = NULL) {
    thread_id <- as.character(thread_id %||% "")
    if (!nzchar(thread_id)) return(FALSE)
    project <- add(project %||% state$current)
    if (is.null(project)) return(FALSE)
    existing <- get0(thread_id, envir = state$bindings, inherits = FALSE)
    if (!is.null(existing)) return(identical(existing, project))
    assign(thread_id, project, envir = state$bindings)
    TRUE
  }

  project_for <- function(thread_id = NULL, project = NULL) {
    thread_id <- as.character(thread_id %||% "")
    explicit <- add(project)
    if (nzchar(thread_id)) {
      existing <- get0(thread_id, envir = state$bindings, inherits = FALSE)
      if (!is.null(explicit) && !identical(existing, explicit)) {
        assign(thread_id, explicit, envir = state$bindings)
        return(explicit)
      }
      if (!is.null(existing)) return(existing)
    }
    candidate <- explicit %||% add(state$current)
    if (nzchar(thread_id) && !is.null(candidate)) bind(thread_id, candidate)
    candidate
  }

  list(
    projects = function() state$projects,
    current = function() state$current,
    add = add,
    remove = function(project) {
      project <- .canonical_workspace_project(project)
      if (is.null(project)) return(state$projects)
      state$projects <- setdiff(state$projects, project)
      if (identical(state$current, project)) {
        state$current <- if (length(state$projects)) state$projects[[1L]] else NULL
      }
      state$projects
    },
    select = function(project) {
      project <- add(project)
      if (!is.null(project)) state$current <- project
      project
    },
    bind = bind,
    project_for = project_for
  )
}

.workspace_session_snapshot <- function(projects, archived_path,
                                        list_sessions = list_claude_sessions) {
  projects <- .canonical_workspace_projects(projects)
  sessions <- list()
  for (project in projects) {
    # Keep missing projects in the registry, but do not query an unavailable SDK
    # transcript directory until it exists again.
    if (!dir.exists(project)) next
    archived_ids <- .read_archived_ids(archived_path, project)
    project_sessions <- tryCatch(
      .call_compatible_callback(
        list_sessions,
        list(directory = project, archived_ids = archived_ids)
      ),
      error = function(e) list()
    ) %||% list()
    project_sessions <- lapply(project_sessions, function(session) {
      session$project <- project
      session$projectLabel <- .workspace_project_label(project)
      session
    })
    sessions <- c(sessions, project_sessions)
  }
  sessions
}
