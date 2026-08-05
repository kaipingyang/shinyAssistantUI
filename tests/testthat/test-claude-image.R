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

test_that(".claude_message_content omits the empty text block for image-only sends", {
  g <- shinyAssistantUI:::.claude_message_content
  # image-only (empty / whitespace message) -> ONLY image blocks, no empty text block
  only <- g("", list("data:image/png;base64,AAA"))
  expect_length(only, 1)
  expect_identical(only[[1]]$type, "image")
  only_ws <- g("   ", list("data:image/png;base64,AAA"))
  expect_length(only_ws, 1)
  expect_identical(only_ws[[1]]$type, "image")
  # with text -> [text, image]
  both <- g("hi", list("data:image/png;base64,AAA"))
  expect_length(both, 2)
  expect_identical(both[[1]]$type, "text")
  expect_identical(both[[2]]$type, "image")
  # no images -> the plain string (unchanged)
  expect_identical(g("just text", list()), "just text")
})
