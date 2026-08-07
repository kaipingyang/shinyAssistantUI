# 任务 D：只揭示最近一次成功编辑的文件（run 结束时 flush 一次）
test_that(".new_edit_reveal_tracker 只在 run 结束返回最近一次成功编辑", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()

  tracker$note_call("t1", "Edit", list(file_path = "R/a.R"))
  tracker$note_result("t1", is_error = FALSE)
  tracker$note_call("t2", "Write", list(file_path = "R/b.R"))
  tracker$note_result("t2", is_error = FALSE)

  # 多个成功编辑 → flush 只返回最近一次
  expect_identical(tracker$flush(), "R/b.R")
  # flush 后清空
  expect_null(tracker$flush())
})

test_that(".new_edit_reveal_tracker 忽略非编辑工具与失败结果", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()

  # 非编辑工具不记录
  tracker$note_call("r1", "Read", list(file_path = "R/a.R"))
  tracker$note_result("r1", is_error = FALSE)
  expect_null(tracker$flush())

  # 编辑但结果失败 → 不揭示
  tracker$note_call("e1", "Edit", list(file_path = "R/a.R"))
  tracker$note_result("e1", is_error = TRUE)
  expect_null(tracker$flush())

  # 成功编辑覆盖失败：最近一次成功才算
  tracker$note_call("e2", "Edit", list(file_path = "R/ok.R"))
  tracker$note_result("e2", is_error = TRUE)
  tracker$note_call("e3", "MultiEdit", list(file_path = "R/win.R"))
  tracker$note_result("e3", is_error = FALSE)
  expect_identical(tracker$flush(), "R/win.R")
})

test_that(".new_edit_reveal_tracker 支持 path 别名且无 file_path 时忽略", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()
  tracker$note_call("n1", "NotebookEdit", list(path = "notebooks/x.ipynb"))
  tracker$note_result("n1", is_error = FALSE)
  expect_identical(tracker$flush(), "notebooks/x.ipynb")

  tracker$note_call("n2", "Edit", list(old_string = "a", new_string = "b"))
  tracker$note_result("n2", is_error = FALSE)
  expect_null(tracker$flush())
})


test_that(".addin_resolve_file_path resolves root and unique hot-index files", {
  project <- tempfile("open-file-")
  dir.create(file.path(project, "subfolder"), recursive = TRUE)
  root_file <- file.path(project, "root.R")
  nested_file <- file.path(project, "subfolder", "dm.R")
  file.create(root_file, nested_file)

  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path("root.R", project),
    normalizePath(root_file, winslash = "/")
  )
  peek <- function() list(list(kind = "file", path = "subfolder/dm.R"))
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path("dm.R", project, peek),
    normalizePath(nested_file, winslash = "/")
  )
})

test_that(".addin_resolve_file_path keeps cold, missing, ambiguous and stale fallbacks silent", {
  project <- tempfile("open-file-")
  dir.create(project)

  expect_null(shinyAssistantUI:::.addin_resolve_file_path("dm.R", project, function() NULL))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "subfolder/ae.R"))
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project,
    function() list(
      list(kind = "file", path = "adam/dm.R"),
      list(kind = "file", path = "sdtm/dm.R")
    )
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "deleted/dm.R"))
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "../dm.R"))
  ))
})

test_that(".addin_open_file no longer repeats rstudioapi isAvailable per click", {
  source_text <- paste(deparse(body(shinyAssistantUI:::.addin_open_file)), collapse = "\n")
  expect_false(grepl("isAvailable", source_text, fixed = TRUE))
  expect_true(grepl("getSourceEditorContext", source_text, fixed = TRUE))
  expect_true(grepl("navigateToFile", source_text, fixed = TRUE))
})


test_that(".addin_resolve_file_path safely handles a repeated cwd basename prefix", {
  parent <- tempfile("open-file-prefix-")
  project <- file.path(parent, "ERP")
  dir.create(project, recursive = TRUE)
  name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
  root_file <- file.path(project, name)
  file.create(root_file)

  # cwd已经是ERP；Claude输出ERP/file时，direct ERP/ERP/file不存在才回退根文件。
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP", name), project),
    normalizePath(root_file, winslash = "/")
  )
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(paste0("ERP\\\\", name), project),
    normalizePath(root_file, winslash = "/")
  )
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP-copy", name), project)
  )

  # 若真实ERP/ERP/file存在，即使根目录有同名文件，也必须由direct candidate优先命中。
  nested_dir <- file.path(project, "ERP")
  dir.create(nested_dir)
  nested_file <- file.path(nested_dir, name)
  file.create(nested_file)
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP", name), project),
    normalizePath(nested_file, winslash = "/")
  )
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(paste0("ERP\\\\", name), project),
    normalizePath(nested_file, winslash = "/")
  )

  # fallback和相对direct候选都不得通过..或symlink逃出cwd；显式绝对路径保持兼容。
  outside <- file.path(parent, "outside.md")
  file.create(outside)
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path("ERP/../outside.md", project)
  )
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path("ERP/../../outside.md", project)
  )
  outside_link <- file.path(nested_dir, "outside-link.md")
  if (isTRUE(file.symlink(outside, outside_link))) {
    expect_null(
      shinyAssistantUI:::.addin_resolve_file_path("ERP/outside-link.md", project)
    )
  }
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(outside, project),
    normalizePath(outside, winslash = "/")
  )
})
