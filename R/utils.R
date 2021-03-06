#
# (c) 2012 -- 2014 Georgios Gousios <gousiosg@gmail.com>
#
# BSD licensed, see LICENSE in top level dir
#

library(methods)
library(data.table)
library(foreach)
library(cliffsd)

# printf for R
printf <- function(...) invisible(print(sprintf(...)))

unwrap <- function(str) {
  strwrap(str, width=10000, simplify=TRUE)
}

## Data loading and conversions

# Trim whitespace from strings
trim <- function (x) gsub("^\\s+|\\s+$", "", x)

# Decide whether a value is an integer
is.integer <- function(N){
  !length(grep("[^[:digit:]]", format(N, scientific = FALSE)))
}

# Load an preprocess all data
load.data <- function(projects.file = "projects.txt") {
  all <- load.all.df(dir=data.file.location, pattern="*.csv$", projects.file)
  subset(all, !is.na(src_churn))
}

# Determine which files to load and return a list of paths
which.to.load <- function(dir = ".", pattern = "*.csv$",
                          projects.file = "projects.txt") {
  if(file.exists(projects.file)) {
    joiner <- function(x){
      owner <- x[[1]]
      repo <- x[[2]]
      sprintf("%s/%s@%s.csv", dir, owner, repo)
    }
    apply(read.csv(projects.file, sep = " ", header=FALSE), c(1), joiner)
  } else {
    list.files(path = dir, pattern = pattern, full.names = T)
  }
}

# Load all files matching the pattern as a single dataframe
load.all.df <- function(dir = ".", pattern = "*.csv$",
                        projects.file = "projects.txt") {
  script = "
    head -n 1 `head -n 1 to_load.txt`
    cat to_load.txt|while read f; do cat $f|sed -e 1d; done
  "
  to.load <- which.to.load(dir, pattern, projects.file)
  write.table(to.load, file='to_load.txt', row.names = FALSE, col.names = FALSE,
              quote = FALSE)
  printf("Loading %d files from %s", length(to.load), projects.file)
  tryCatch({
    load.filter(pipe(script))
  }, finally= {
    printf("Done loading files")
    unlink("to_load.txt")
  })
}

# Load all files matching the pattern as a list of data frames
# The projects_file argument specifies an optional list of files to load.
# If the provided projects_file does not exist, all data files will be loaded
load.all <- function(dir = ".", pattern = "*.csv$",
                     projects.file = "projects.txt") {

  to_load <- which.to.load(dir, pattern, projects.file)

  l <- foreach(x = to_load, .combine=c) %dopar% {
    if (file.exists(x)) {
      print(sprintf("Reading file %s", x))
      
      a <- tryCatch(load.filter(x), 
                    error = function(e){print(e); data.table()})
      if (nrow(a) == 0) {
        printf("Warning - No rows in file %s", x)
        list()
      } else {
        list(a)
      }
    } else {
      printf("File does not exist %s", x)
      list()
    }
  }

  rbindlist(l)
}

# Load some dataframes
load.some <- function(dir = ".", pattern = "*.csv$", howmany = -1) {
  l = Reduce(function(acc, file){
    if (length(acc) <= howmany) {
      dt <- load.filter(file)
      printf("Loaded file %s (%d rows)", file, nrow(dt))
      c(acc, list(dt))
    } else {
      print(sprintf("Ignoring file %s", file))
      acc
    }
  }, list.files(path = dir, pattern = pattern, full.names = T),
  c())

  rbindlist(l)
}

load.filter <- function(path) {
  setAs("character", "POSIXct",
        function(from){as.POSIXct(from, origin = "1970-01-01")})

  a <- read.csv(path, check.names = T, 
                colClasses = c(
                "integer",      #pull_req_id
                "factor",       #project_name
                "factor",       #lang
                "integer",      #github_id
                "integer",      #created_at
                "integer",      #merged_at
                "integer",      #closed_at
                "integer",      #lifetime_minutes
                "integer",      #mergetime_minutes
                "factor",       #merged_using
                "factor",       #conflict
                "factor",       #forward_links
                "factor",       #intra_branch
                "integer",      #description_length
                "integer",      #num_commits
                "integer",      #num_commits_open
                "integer",      #num_pr_comments
                "integer",      #num_issue_comments
                "integer",      #num_commit_comments
                "integer",      #num_comments
                "integer",      #num_commit_comments_open
                "integer",      #num_participants
                "integer",      #files_added_open
                "integer",      #files_deleted_open
                "integer",      #files_modified_open
                "integer",      #files_changed_open
                "integer",      #src_files_open
                "integer",      #doc_files_open
                "integer",      #other_files_open
                "integer",      #files_added
                "integer",      #files_deleted
                "integer",      #files_modified
                "integer",      #files_changed
                "integer",      #src_files
                "integer",      #doc_files
                "integer",      #other_files
                "integer",      #src_churn_open
                "integer",      #test_churn_open
                "integer",      #src_churn
                "integer",      #test_churn
                "numeric",      #new_entropy
                "numeric",      #entropy_diff
                "integer",      #commits_on_files_touched
                "integer",      #commits_to_hottest_file
                "numeric",      #hotness
                "integer",      #at_mentions_description
                "integer",      #at_mentions_comments
                "numeric",      #perc_external_contribs
                "integer",      #sloc
                "numeric",      #test_lines_per_kloc
                "numeric",      #test_cases_per_kloc
                "numeric",      #asserts_per_kloc
                "integer",      #stars
                "integer",      #team_size
                "integer",      #workload
                "factor",       #ci
                "factor",       #requester
                "factor",       #closer
                "factor",       #merger
                "integer",      #prev_pullreqs
                "numeric",      #requester_succ_rate
                "integer",      #followers
                "factor",       #main_team_member
                "factor",       #social_connection
                "integer",      #prior_interaction_issue_events
                "integer",      #prior_interaction_issue_comments
                "integer",      #prior_interaction_pr_events
                "integer",      #prior_interaction_pr_comments
                "integer",      #prior_interaction_commits
                "integer",      #prior_interaction_commit_comments
                "integer"      #first_response
                )
  )

  a$prior_interaction_comments <- a$prior_interaction_issue_comments + a$prior_interaction_pr_comments + a$prior_interaction_commit_comments
  a$prior_interaction_events <- a$prior_interaction_issue_events + a$prior_interaction_pr_events + a$prior_interaction_commits

  a$has_ci <- a$ci != 'unknown'
  a$has_ci <- as.factor(a$has_ci)

  a$merged <- !is.na(a$merged_at)
  a$merged <- as.factor(a$merged)
#   # Take care of cases where csv file production was interupted, so the last
#   # line has wrong fields
  a <- subset(a, !is.na(first_response))
  data.table(a)
}

# Name of a project in a dataframe
project.name <- function(dataframe) {
  as.character(dataframe$project_name[[1]])
}

# Get a project dataframe from the provided data frame list whose name is dfs
get.project <- function(dfs, name) {
  Find(function(x){if(project.name(x) == name){T} else {F} }, dfs)
}

# Merge dataframes
merge.dataframes <- function(dfs, min_num_rows = 1) {
  Reduce(function(acc, x){
        printf("Merging dataframe %s", project.name(x))
        if (nrow(x) >= min_num_rows) {
          rbind(acc, x)
        } else {
          printf("Warning: %s has less than %d rows (%d), skipping", project.name(x), min_num_rows, nrow(x))
          acc
        }
      }, dfs)
}

## Various utilities

# Prints a list of column along with a boolean value. If the value is FALSE, then
# the column contains at least one NA value
column.contains.na <- function(df) {
  for (b in colnames(df)){print(sprintf("%s %s", b, all(!is.na(a.train[[b]]))))}
}

# Run the Matt-Whitney test on input vectors a and b and report relevant metrics
ranksum <- function (a, b, title = "") {
  w <- wilcox.test(a, b)
  d <- cliffs.d(a, b)
  printf("%s sizes: a: %d b: %d, medians a: %f b: %f, means a: %f, b: %f, wilcox: %f, p: %f, d: %f", 
         title, length(a), length(b), median(a), median(b), mean(a), mean(b), w$statistic, 
         w$p.value, d)
}

## Plot storage

# Store multiple plots on the same PDF
store.multi <- function(printer, data, cols, name, where = "~/")
{
  pdf(paste(where, paste(name, "pdf", sep=".")), width = 11.7, height = 16.5, title = name)
  printer <- match.fun(printer)
  printer(data, cols)
  dev.off()
}

# Store a plot as PDF. By default, will store to user's home directory
store.pdf <- function(data, where, name)
{
  pdf(paste(where,name, sep="/"))
  plot(data)
  dev.off()
}

# Get the owner part form a "owner/repo" repository naming
owner <- function(repo.name) {
  unlist(strsplit(repo.name, '/'))[1]
}

# Get the repo part form a "owner/repo" repository naming
repo <- function(repo.name) {
  unlist(strsplit(repo.name, '/'))[2]
}

# Simple outlier technique
outlier.threshold <- function(x, at.least=0.02, at.most=0.03) {
  z <- quantile(x, 1 - at.least)
  y <- quantile(x, 1 - at.most)
  mean(c(z ,y))
}

remove.outliers <- function(x) {
  threshold <- outlier.threshold(x)
  Filter(function(y){ y < threshold}, x)
}