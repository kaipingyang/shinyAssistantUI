test_that("load_claude_skills discovers direct personal and project skills", {
  old_home <- Sys.getenv("HOME", unset = NA_character_)
  home <- tempfile("claude-home-")
  project <- tempfile("claude-project-")
  dir.create(home, recursive = TRUE)
  dir.create(project, recursive = TRUE)
  Sys.setenv(HOME = home)
  on.exit({
    if (is.na(old_home)) Sys.unsetenv("HOME") else Sys.setenv(HOME = old_home)
  }, add = TRUE)

  write_skill <- function(base, name, description, extra = character()) {
    path <- file.path(base, ".claude", "skills", name, "SKILL.md")
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(c("---", paste0("description: ", description), extra, "---", "Skill body"), path)
  }

  write_skill(home, "personal-only", "Personal skill")
  write_skill(project, "project-only", "Project skill")
  write_skill(project, "shared", "Project version")
  write_skill(home, "shared", "Personal version")
  write_skill(home, "hidden", "Hidden skill", "user-invocable: false")

  # A repository embedded under one personal skill must not leak its own skills.
  leaked <- file.path(home, ".claude", "skills", "personal-only", "vendor",
                      ".claude", "skills", "leaked", "SKILL.md")
  dir.create(dirname(leaked), recursive = TRUE)
  writeLines(c("---", "description: Must not appear", "---", "No"), leaked)

  skills <- load_claude_skills(project_dir = project, include_plugins = FALSE)
  by_name <- stats::setNames(skills, vapply(skills, `[[`, character(1), "name"))

  expect_setequal(names(by_name), c("personal-only", "project-only", "shared"))
  expect_identical(by_name$shared$description, "Personal version")
  expect_identical(by_name$shared$source, "personal")
  expect_identical(by_name$`project-only`$source, "project")
  expect_identical(by_name$`personal-only`$prompt, "/personal-only")
  expect_identical(by_name$`project-only`$category, "Project Skills")
})

test_that("skills beat legacy commands within a scope and personal scope beats project", {
  old_home <- Sys.getenv("HOME", unset = NA_character_)
  home <- tempfile("claude-home-")
  project <- tempfile("claude-project-")
  dir.create(home, recursive = TRUE)
  dir.create(project, recursive = TRUE)
  Sys.setenv(HOME = home)
  on.exit({
    if (is.na(old_home)) Sys.unsetenv("HOME") else Sys.setenv(HOME = old_home)
  }, add = TRUE)

  write_command <- function(base, name, description) {
    path <- file.path(base, ".claude", "commands", paste0(name, ".md"))
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(c("---", paste0("description: ", description), "---", "Command body"), path)
  }
  write_skill <- function(base, name, description) {
    path <- file.path(base, ".claude", "skills", name, "SKILL.md")
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(c("---", paste0("description: ", description), "---", "Skill body"), path)
  }

  write_command(project, "same-scope", "Project command")
  write_skill(project, "same-scope", "Project skill")
  write_skill(project, "cross-scope", "Project skill")
  write_command(home, "cross-scope", "Personal command")

  skills <- load_claude_skills(project_dir = project, include_plugins = FALSE)
  by_name <- stats::setNames(skills, vapply(skills, `[[`, character(1), "name"))

  expect_identical(by_name$`same-scope`$description, "Project skill")
  expect_identical(by_name$`same-scope`$kind, "skill")
  expect_identical(by_name$`cross-scope`$description, "Personal command")
  expect_identical(by_name$`cross-scope`$source, "personal")
})

test_that("skillOverrides off hides locally discovered skills", {
  old_home <- Sys.getenv("HOME", unset = NA_character_)
  home <- tempfile("claude-home-")
  project <- tempfile("claude-project-")
  dir.create(file.path(home, ".claude", "skills", "disabled"), recursive = TRUE)
  dir.create(project, recursive = TRUE)
  Sys.setenv(HOME = home)
  on.exit({
    if (is.na(old_home)) Sys.unsetenv("HOME") else Sys.setenv(HOME = old_home)
  }, add = TRUE)
  writeLines(c("---", "description: Disabled", "---", "Body"),
             file.path(home, ".claude", "skills", "disabled", "SKILL.md"))
  writeLines('{"skillOverrides":{"disabled":"off"}}',
             file.path(home, ".claude", "settings.json"))

  skills <- load_claude_skills(project_dir = project, include_plugins = FALSE)
  expect_false("disabled" %in% vapply(skills, `[[`, character(1), "name"))
})
