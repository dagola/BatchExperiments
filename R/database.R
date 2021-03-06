#' @export
dbCreateJobDefTable.ExperimentRegistry = function(reg) {
  query = sprintf(paste("CREATE TABLE %s_job_def (job_def_id INTEGER PRIMARY KEY,",
                        "prob_id TEXT, prob_pars TEXT, algo_id TEXT, algo_pars TEXT,",
                        "UNIQUE(prob_id, prob_pars, algo_id, algo_pars))"), reg$id)
  batchQuery(reg, query, flags = "rwc")
}

dbCreateExtraTables = function(reg) {
  query = sprintf("CREATE TABLE %s_prob_def (prob_id TEXT PRIMARY KEY, pseed INTEGER)", reg$id)
  batchQuery(reg, query, flags = "rwc")
  query = sprintf("CREATE TABLE %s_algo_def (algo_id TEXT PRIMARY KEY)", reg$id)
  batchQuery(reg, query, flags = "rwc")
}

dbCreateExpandedJobsViewBE = function(reg) {
  query = sprintf(paste("CREATE VIEW %1$s_expanded_jobs AS",
                        "SELECT * FROM %1$s_job_status AS job_status",
                        "LEFT JOIN %1$s_job_def AS job_def USING(job_def_id)",
                        "LEFT JOIN %1$s_prob_def AS prob_def USING (prob_id)"), reg$id)
  batchQuery(reg, query, flags = "rw")
}


dbSelectWithIds = function(reg, query, ids, where = TRUE, group.by, reorder = TRUE) {
  if(!missing(ids))
    query = sprintf("%s %s job_id IN (%s)", query, ifelse(where, "WHERE", "AND"), collapse(ids))
  if(!missing(group.by))
    query = sprintf("%s GROUP BY %s", query, collapse(group.by))

  res = batchQuery(reg, query)
  if(missing(ids) || !reorder)
    return(res)
  return(res[na.omit(match(ids, res$job_id)),, drop = FALSE])
}

#' @method dbGetJobs ExperimentRegistry
#' @export
dbGetJobs.ExperimentRegistry = function(reg, ids) {
  query = sprintf("SELECT job_id, prob_id, prob_pars, algo_id, algo_pars, seed, prob_seed, repl FROM %s_expanded_jobs", reg$id)
  tab = dbSelectWithIds(reg, query, ids)

  lapply(seq_row(tab), function(i) {
    x = tab[i,]
    prob.pars = unserialize(charToRaw(x$prob_pars))
    algo.pars = unserialize(charToRaw(x$algo_pars))
    makeExperimentJob(id = x$job_id, prob.id = x$prob_id, prob.pars = prob.pars,
      algo.id = x$algo_id, algo.pars = algo.pars, seed = x$seed, repl = x$repl, prob.seed = x$prob_seed)
  })
}


dbSummarizeExperiments = function(reg, ids, show) {
  if (all(show %in% c("prob", "algo", "repl"))) {
    cols = setNames(c("prob_id", "algo_id", "repl"), c("prob", "algo", "repl"))
    cols = cols[match(show, names(cols))]
    query = sprintf("SELECT %s, COUNT(job_id) FROM %s_expanded_jobs", collapse(cols), reg$id)
    summary = setNames(dbSelectWithIds(reg, query, ids, group.by = cols, reorder = FALSE),
                       c(show, ".count"))
  } else {
    uc = function(x) unserialize(charToRaw(x))
    query = sprintf("SELECT job_id, prob_id AS prob, prob_pars, algo_id AS algo, algo_pars, repl FROM %s_expanded_jobs", reg$id)
    tab = as.data.table(dbSelectWithIds(reg, query, ids, reorder = FALSE))
    pars = rbindlist(lapply(tab$prob_pars, uc), fill = TRUE)
    if (nrow(pars) > 0L)
      tab = cbind(tab, pars)
    pars = rbindlist(lapply(tab$algo_pars, uc), fill = TRUE)
    if (nrow(pars) > 0L)
      tab = cbind(tab, pars)

    diff = setdiff(show, colnames(tab))
    if (length(diff) > 0L)
      stopf("Trying to select columns in arg 'show' which are not available: %s", collapse(diff))
    summary = as.data.frame(tab[, list(.count = .N), by = show])
  }
  summary
}


dbFindExperiments = function(reg, ids, prob.pattern, algo.pattern, repls, like = TRUE, regexp = FALSE) {
  clause = character(0L)
  if (!missing(repls))
    clause = c(clause, sprintf("repl IN (%s)", collapse(repls)))

  if (regexp) {
    query = sprintf("SELECT job_id, prob_id, algo_id from %s_expanded_jobs", reg$id)
    tab = dbSelectWithIds(reg, query, ids, where = TRUE)
    ss = rep(TRUE, nrow(tab))
    if (!missing(prob.pattern))
      ss = ss & grepl(prob.pattern, tab$prob_id)
    if (!missing(algo.pattern))
      ss = ss & grepl(algo.pattern, tab$algo_id)
    return(tab$job_id[ss])
  }

  if (!missing(prob.pattern)) {
    if (like)
      clause = c(clause, sprintf("prob_id LIKE '%%%s%%'", prob.pattern))
    else
      clause = c(clause, sprintf("prob_id = '%s'", prob.pattern))
  }
  if (!missing(algo.pattern)) {
    if (like)
      clause = c(clause, sprintf("algo_id LIKE '%%%s%%'", algo.pattern))
    else
      clause = c(clause, sprintf("algo_id = '%s'", algo.pattern))
  }

  query = sprintf("SELECT job_id from %s_expanded_jobs", reg$id)
  if (length(clause) > 0L)
    query = paste(query, "WHERE", collapse(clause, sep = " AND "))
  dbSelectWithIds(reg, query, ids, where = length(clause) == 0L)$job_id
}

dbAddProblem = function(reg, id, seed) {
  #FIXME: replace OR REPLACE with an option, this is not supported by all DBMS
  query = sprintf("INSERT OR REPLACE INTO %s_prob_def (prob_id, pseed) VALUES ('%s', %s)",
                  reg$id, id, ifelse(is.null(seed), "NULL", seed))
  batchQuery(reg, query, flags = "rw")
}

dbAddAlgorithm = function(reg, id) {
  #FIXME: replace OR REPLACE with an option, this is not supported by all DBMS
  query = sprintf("INSERT OR REPLACE INTO %s_algo_def (algo_id) VALUES ('%s')", reg$id, id)
  batchQuery(reg, query, flags = "rw")
}

dbRemoveProblem = function(reg, id) {
  query = sprintf("DELETE FROM %s_prob_def WHERE prob_id='%s'", reg$id, id)
  batchQuery(reg, query, flags = "rw")
}

dbRemoveAlgorithm = function(reg, id) {
  query = sprintf("DELETE FROM %s_algo_def WHERE algo_id='%s'", reg$id, id)
  batchQuery(reg, query, flags = "rw")
}

dbGetAllProblemIds = function(reg) {
  query = sprintf("SELECT prob_id FROM %s_prob_def", reg$id)
  batchQuery(reg, query)$prob_id
}

dbGetAllAlgorithmIds = function(reg) {
  query = sprintf("SELECT algo_id FROM %s_algo_def", reg$id)
  batchQuery(reg, query)$algo_id
}

dbGetProblemIds = function(reg, ids) {
  query = sprintf("SELECT job_id, prob_id FROM %s_expanded_jobs", reg$id)
  dbSelectWithIds(reg, query, ids)$prob_id
}

dbGetAlgorithmIds = function(reg, ids) {
  query = sprintf("SELECT job_id, prob_id FROM %s_expanded_jobs", reg$id)
  dbSelectWithIds(reg, query, ids)$algo_id
}

dbRemoveJobs = function(reg, ids) {
  query = sprintf("DELETE FROM %s_job_status WHERE job_id IN (%s)", reg$id, collapse(ids))
  batchQuery(reg, query, flags = "rw")
  query = sprintf("DELETE FROM %1$s_job_def WHERE job_def_id NOT IN (SELECT DISTINCT job_def_id FROM %1$s_job_status)", reg$id)
  batchQuery(reg, query, flags = "rw")
  return(invisible(TRUE))
}
