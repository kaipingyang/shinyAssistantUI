# Regression: image upload path must NOT call the non-existent ClaudeSDKClient
# method send_with_images() (crashed with "attempt to apply non-function"); images
# ride as Anthropic content blocks via .claude_image_block() -> client$send(list).

test_that(".claude_image_block builds a base64 block from a data URI", {
  f <- shinyAssistantUI:::.claude_image_block
  b <- f("data:image/png;base64,AAABBB")
  expect_identical(b$type, "image")
  expect_identical(b$source$type, "base64")
  expect_identical(b$source$media_type, "image/png")
  expect_identical(b$source$data, "AAABBB")
})

test_that(".claude_image_block falls back to a url block for non-data URIs", {
  f <- shinyAssistantUI:::.claude_image_block
  b <- f("https://example.com/x.jpg")
  expect_identical(b$type, "image")
  expect_identical(b$source$type, "url")
  expect_identical(b$source$url, "https://example.com/x.jpg")
})

test_that("image content blocks assemble as [text, image] for client$send()", {
  f <- shinyAssistantUI:::.claude_image_block
  full_message <- "what is this?"
  img_parts <- list("data:image/jpeg;base64,ZZZ")
  blocks <- c(list(list(type = "text", text = full_message)), lapply(img_parts, f))
  expect_length(blocks, 2)
  expect_identical(blocks[[1]]$type, "text")
  expect_identical(blocks[[2]]$type, "image")
  expect_identical(blocks[[2]]$source$media_type, "image/jpeg")
})
