test_that(".addin_git_branch reports a symbolic branch and detached commit", {
  skip_if(Sys.which("git") == "", "git is required")
  project <- tempfile("branch project [safe] ")
  dir.create(project)
  system2("git", c("-C", shQuote(project), "init", "-q"))
  system2("git", c("-C", shQuote(project), "config", "user.email", "test@example.invalid"))
  system2("git", c("-C", shQuote(project), "config", "user.name", "Test User"))
  writeLines("one", file.path(project, "tracked.txt"))
  system2("git", c("-C", shQuote(project), "add", "tracked.txt"))
  system2("git", c("-C", shQuote(project), "commit", "-q", "-m", shQuote("initial")))
  system2("git", c("-C", shQuote(project), "branch", "-M", "feature/footer"))

  expect_identical(shinyAssistantUI:::.addin_git_branch(project), "feature/footer")

  sha <- system2("git", c("-C", shQuote(project), "rev-parse", "--short=8", "HEAD"), stdout = TRUE)
  system2("git", c("-C", shQuote(project), "checkout", "-q", "--detach"))
  expect_identical(
    shinyAssistantUI:::.addin_git_branch(project),
    paste0("detached@", sha[[1L]])
  )
})

test_that(".addin_git_branch returns NULL outside Git and rejects invalid paths", {
  plain <- tempfile("not git ; $(safe) ")
  dir.create(plain)
  expect_null(shinyAssistantUI:::.addin_git_branch(plain))
  expect_null(shinyAssistantUI:::.addin_git_branch(file.path(plain, "missing")))
  expect_null(shinyAssistantUI:::.addin_git_branch(NULL))
})


test_that("cancelled runs refresh Git branch for their project snapshot", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  provider_projects <- character()
  handler <- function(register_cancel, ...) {
    promises::promise(function(resolve, reject) {
      register_cancel(function() resolve(NULL))
    })
  }

  drain_loop <- function(seconds = 0.12) {
    deadline <- Sys.time() + seconds
    repeat {
      later::run_now(0)
      if (Sys.time() >= deadline) break
      Sys.sleep(0.005)
    }
    later::run_now(0)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      working_dir = "/project-default",
      git_branch_provider = function(project) {
        provider_projects <<- c(provider_projects, project)
        "feature/refreshed"
      }
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "hold", threadId = "thread-a", runId = "run-a",
      project = "/project-snapshot", ts = 1
    ))
    session$flushReact()
    drain_loop()
    expect_length(provider_projects, 0L)

    session$setInputs(chat_input_cancel = list(
      threadId = "thread-a", runId = "run-a", ts = 2
    ))
    session$flushReact()
    drain_loop()

    expect_identical(provider_projects, "/project-snapshot")
  })
})
