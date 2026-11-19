# Plan 168 B3: AskUserForm path fields, checked on the server when submitted.
validate <- function(fields) shinyAssistantUI:::.ask_form_validate_fields(fields)
collect <- function(spec, values) shinyAssistantUI:::.ask_form_collect(spec, values)

make_tree <- function() {
  root <- withr::local_tempdir(.local_envir = parent.frame())
  dir.create(file.path(root, "tools"))
  writeLines("x", file.path(root, "protocol.docx"))
  writeLines("x", file.path(root, "notes.txt"))
  normalizePath(root)
}

test_that("path options are validated", {
  spec <- validate(list(list(name = "p", type = "path", kind = "file", extensions = list(".docx", "DOCX"),
                             must_exist = TRUE, placeholder = "/mnt/.../protocol.docx")))
  expect_true(is.list(spec))
  expect_identical(spec[[1]]$kind, "file")
  expect_identical(spec[[1]]$extensions, "docx")
  expect_true(spec[[1]]$must_exist)
  expect_identical(validate(list(list(name = "p", type = "path")))[[1]]$kind, "any")
  expect_true(validate(list(list(name = "p", type = "path")))[[1]]$must_exist)
  bad <- list(
    list(list(name = "p", type = "path", kind = "folder")),
    list(list(name = "p", type = "path", kind = "dir", extensions = list("docx"))),
    list(list(name = "p", type = "text", kind = "file")),
    list(list(name = "p", type = "text", extensions = list("docx"))),
    list(list(name = "p", type = "path", extensions = list("a/b"))),
    list(list(name = "p", type = "path", extensions = as.list(paste0("e", 1:21))))
  )
  for (fields in bad) expect_type(validate(fields), "character")
})

test_that("existing files, directories and extensions are checked", {
  root <- make_tree()
  spec <- validate(list(
    list(name = "doc", label = "Protocol", type = "path", kind = "file", extensions = list("docx")),
    list(name = "dir", label = "Tools folder", type = "path", kind = "dir"),
    list(name = "any", label = "Anything", type = "path")
  ))
  ok <- collect(spec, list(doc = file.path(root, "protocol.docx"), dir = paste0(file.path(root, "tools"), "/"),
                           any = file.path(root, "notes.txt")))
  expect_length(ok$problems, 0L)
  expect_identical(ok$values$doc, file.path(root, "protocol.docx"))
  expect_identical(ok$values$dir, file.path(root, "tools"))

  bad <- collect(spec, list(doc = file.path(root, "notes.txt"), dir = file.path(root, "protocol.docx"),
                            any = file.path(root, "missing.R")))
  expect_true(any(grepl("Protocol must be a .docx file", bad$problems, fixed = TRUE)))
  expect_true(any(grepl("Tools folder must be a folder", bad$problems, fixed = TRUE)))
  expect_true(any(grepl("Anything does not exist", bad$problems, fixed = TRUE)))

  wrong_kind <- collect(spec, list(doc = file.path(root, "tools"), dir = "", any = ""))
  expect_true(any(grepl("Protocol must be a file", wrong_kind$problems, fixed = TRUE)))
})

test_that("relative paths are rejected and ~ is expanded", {
  root <- make_tree()
  spec <- validate(list(list(name = "p", label = "Path", type = "path", must_exist = FALSE)))
  rel <- collect(spec, list(p = "tools/x"))
  expect_true(any(grepl("Path must be an absolute path", rel$problems, fixed = TRUE)))
  withr::local_envvar(HOME = root)
  home <- collect(spec, list(p = "~/new-folder"))
  expect_length(home$problems, 0L)
  expect_identical(home$values$p, file.path(root, "new-folder"))
})

test_that("a path that need not exist still checks the extension and the parent", {
  root <- make_tree()
  spec <- validate(list(list(name = "out", label = "Output", type = "path", kind = "file",
                             must_exist = FALSE, extensions = list("xlsx"))))
  expect_length(collect(spec, list(out = file.path(root, "spec.xlsx")))$problems, 0L)
  expect_true(any(grepl(".xlsx file", collect(spec, list(out = file.path(root, "spec.csv")))$problems,
                        fixed = TRUE)))
  expect_true(any(grepl("parent folder does not exist",
                        collect(spec, list(out = file.path(root, "nope", "spec.xlsx")))$problems, fixed = TRUE)))
})

test_that("path fields render as text inputs and required works", {
  spec <- validate(list(list(name = "p", label = "Study folder", type = "path", kind = "dir",
                             required = TRUE, placeholder = "/mnt/usrfiles/...")))
  ops <- shinyAssistantUI:::.ask_form_surface_ops("ask-form-f1", "T", spec, "Go")
  expect_silent(shinyAssistantUI:::.a2ui_validate_operations(ops))
  components <- ops[[2]]$updateComponents$components
  field <- Filter(function(c) identical(c$id, "field-p"), components)[[1]]
  expect_identical(field$component, "TextField")
  expect_identical(field$placeholder, "/mnt/usrfiles/...")
  expect_true(any(grepl("Please fill in Study folder", collect(spec, list(p = " "))$problems, fixed = TRUE)))
})

test_that("the MCP tool schema advertises path fields", {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1")
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  props <- env$field_schema$properties
  expect_true("path" %in% unlist(props$type$enum))
  expect_true(all(c("kind", "must_exist", "extensions") %in% names(props)))
})

test_that("~user paths are rejected and an extension requires a file", {
  root <- make_tree()
  dir.create(file.path(root, "artifact.docx"))
  spec <- validate(list(list(name = "p", label = "Doc", type = "path", extensions = list("docx")),
                        list(name = "q", label = "Any", type = "path", must_exist = FALSE)))
  expect_true(any(grepl("Any must be an absolute path", collect(spec, list(q = "~root"))$problems, fixed = TRUE)))
  expect_true(any(grepl("Any must be an absolute path", collect(spec, list(q = "~root/x"))$problems, fixed = TRUE)))
  expect_true(any(grepl("Doc must be a file, not a folder",
                        collect(spec, list(p = file.path(root, "artifact.docx")))$problems, fixed = TRUE)))
  withr::local_envvar(HOME = root)
  expect_identical(collect(spec, list(q = "~"))$values$q, root)
  expect_identical(collect(spec, list(q = "//"))$values$q, "/")
})

test_that("dotfiles have no extension; the last suffix counts otherwise", {
  ext <- shinyAssistantUI:::.ask_form_file_ext
  expect_identical(ext("/a/.Renviron"), "")
  expect_identical(ext("/a/.env.local"), "local")
  expect_identical(ext("/a/x.tar.gz"), "gz")
  expect_identical(ext("/a/Protocol.DOCX"), "docx")
  expect_identical(ext("/a/noext"), "")
})
