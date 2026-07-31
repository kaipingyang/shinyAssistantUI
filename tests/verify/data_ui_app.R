# Fixture (Plan 47 A0):handler 经 on_data_ui 下发 table/stat/flow 数据部件。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_data_ui = NULL, ...) {
  on_chunk("Here are your results:\n")
  if (is.function(on_data_ui)) {
    on_data_ui("table", list(rows = list(
      list(var = "age", est = 1.2),
      list(var = "bmi", est = 3.4)
    )))
    on_data_ui("stat", list(label = "R2", value = "0.87"))
    on_data_ui("flow", list(
      nodes = list(list(id = "load", label = "Load"), list(id = "model", label = "Model")),
      edges = list(list(from = "load", to = "model"))
    ))
  }
  on_done()
}

ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "90vh")))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
