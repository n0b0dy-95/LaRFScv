# Import required libraries
library(shiny)
library(data.table)
library(glmnet)
library(ggplot2)
library(dplyr)

# Design the UI
ui <- fluidPage(
  titlePanel("LaRFScv 0.1"),
  
  tags$head(
    tags$style(HTML("
                    body {
                    font-family: 'Arial', sans-serif;
                    margin: 0;
                    padding: 0;
                    background-color: #ffffff;
                    color: #333;
                    }
                    
                    header {
                    background-color: #2c3e50;
                    color: #ecf0f1;
                    padding: 1em;
                    text-align: center;
                    }
                    
                    section {
                    margin: 2em;
                    text-align: center;
                    }
                    
                    .button-container {
                    text-align: center;
                    }
                    
                    .button {
                    display: inline-block;
                    padding: 10px 20px;
                    font-size: 16px;
                    text-align: center;
                    text-decoration: none;
                    background-color: #3498db;
                    color: #fff;
                    border-radius: 5px;
                    transition: background-color 0.3s ease;
                    margin-right: 10px; /* Add margin to create space between buttons */
                    }
                    
                    .button:hover {
                    background-color: #2980b9;
                    }
                    
                    footer {
                    background-color: #34495e;
                    color: #ecf0f1;
                    padding: 1em;
                    text-align: center;
                    position: fixed;
                    bottom: 0;
                    width: 100%;
                    }
                    
                    .message-box {
                    color: #721c24;
                    background-color: #f8d7da;
                    border: 1px solid #f5c6cb;
                    border-radius: 5px;
                    padding: 10px;
                    margin-bottom: 10px;
                    }
                    "))
    ),
  
  sidebarLayout(
    sidebarPanel(
      fileInput("file1", "Choose a CSV file", accept = ".csv"),
      selectInput("y_var", "Select Dependant Data", ""),
      numericInput("cv_folds", "Number of folds for Cross-validation", value = 5, min = 5),
      numericInput("cutoff", "Coefficient Cut-off", value = 0.01, min = 0.001, max = 1),
      numericInput("seed_value", "Seed value", value = 0, min = 0),
      div(class = "button-container",
          actionButton("analyze_button", "Analyze", class = "button"),
          downloadButton("download_csv", "Download CSV", class = "button")
      )
    ),
    
    mainPanel(
      tabsetPanel(
        tabPanel(strong("MSE vs Log Lambda"), plotOutput("plot")),
        tabPanel(strong("Selected Features vs Coefficient"), plotOutput("bar_plot")),
        tabPanel(strong("Selected Features"), tableOutput("table")),
        uiOutput("error_message")
      )
    )
  )
    )

# Function to perform the Lasso-CV
server <- function(input, output, session) {
  
  # Read data file
  data <- reactive({
    req(input$file1)
    df <- tryCatch({
      read.csv(input$file1$datapath, row.names = 1)
    }, error = function(e) {
      return(NULL)
    })
    df
  })
  
  # Update Y variable options based on data file
  observe({
    y_var_options <- names(data())
    updateSelectInput(session, "y_var", choices = y_var_options)
  })
  
  # Update X variable options based on selected Y variable
  x_var_options <- reactive({
    req(input$y_var)
    setdiff(names(data()), c(input$y_var, rownames(data())))
  })
  
  # Extract Y data
  y_data <- reactive({
    req(input$analyze_button)
    data()[[input$y_var]]
  })
  
  # Lasso-CV for identification of the best Lambda
  cv_output <- eventReactive(input$analyze_button, {
    result <- tryCatch({
      set.seed(input$seed_value) # Set the seed value
      cv.glmnet(as.matrix(data()[, x_var_options(), drop = FALSE]), y_data(), alpha = 1, nfolds = input$cv_folds)
    }, error = function(e) {
      return(NULL)
    })
    return(result)
  })
  
  # Plot the MSE vs Lambda values
  output$plot <- renderPlot({
    req(input$analyze_button)
    plot(cv_output())
  })
  
  # Identifying the best lambda
  best_lam <- reactive({
    req(input$analyze_button)
    if (!is.null(cv_output()))
      cv_output()$lambda.min
  })
  
  # Rebuilding the model with the best lambda value identified
  lasso_best <- reactive({
    req(input$analyze_button)
    if (!is.null(best_lam()))
      glmnet(as.matrix(data()[, x_var_options(), drop = FALSE]), y_data(), alpha = 1, lambda = best_lam())
  })
  
  # Get the best Lambda values for Lasso regression
  lasso_best_coeff <- reactive({
    req(input$analyze_button)
    if (!is.null(lasso_best()))
      coef(lasso_best())
  })
  
  # Make a data frame from the lasso coefficients and feature names
  reduced_df <- reactive({
    req(input$analyze_button)
    df <- tryCatch({
      data.frame(feature = rownames(lasso_best_coeff())[-1], coefficient = lasso_best_coeff()[-1])
    }, error = function(e) {
      return(NULL)
    })
    if (!is.null(df)) {
      df <- df[abs(df$coefficient) > input$cutoff, ]
      df <- df[order(abs(df$coefficient), decreasing = TRUE), ]
      df$count <- nrow(df)
    }
    return(df)
  })
  
  # Output results table
  output$table <- renderTable({
    req(input$analyze_button)
    reduced_df()
  })
  
  # Output results bar plot
  output$bar_plot <- renderPlot({
    req(input$analyze_button)
    df <- reduced_df()
    if (!is.null(df)) {
      ggplot(df, aes(x = feature, y = coefficient, fill = coefficient > 0)) +
        geom_col(show.legend = FALSE) +
        coord_flip() +
        theme_bw() +
        xlab("Feature") +
        ylab("Coefficient") +
        ggtitle("Selected Features and Coefficients")
    }
  })
  
  # Downloadable csv file of selected features
  output$download_csv <- downloadHandler(
    filename = function() {
      paste("selected_features_", Sys.Date(), ".csv", sep = "")
    },
    content = function(file) {
      write.csv(reduced_df(), file)
    }
  )
  
  # Error message box
  output$error_message <- renderUI({
    if (is.null(data())) {
      return(
        tags$div(
          class = "message-box",
          "Error: Unable to read the CSV file. Please check if the file is valid."
        )
      )
    }
    NULL
  })
  
  # Add this line to the server function
  session$onSessionEnded(function() {
    rm(list = c("cv_folds", "seed_value"))
  })
}

# Define the app
shinyApp(ui, server)

