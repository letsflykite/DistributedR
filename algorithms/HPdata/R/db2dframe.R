#####################################################################################
# Copyright [2013] Hewlett-Packard Development Company, L.P.                        # 
#                                                                                   #
# This program is free software; you can redistribute it and/or                     #
# modify it under the terms of the GNU General Public License                       #
# as published by the Free Software Foundation; either version 2                    #
# of the License, or (at your option) any later version.                            #
#                                                                                   #
# This program is distributed in the hope that it will be useful,                   #
# but WITHOUT ANY WARRANTY; without even the implied warranty of                    #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the                      #
# GNU General Public License for more details.                                      #
#                                                                                   #
# You should have received a copy of the GNU General Public License                 #
# along with this program; if not, write to the Free Software                       #
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.    #
#####################################################################################

 
## A simple function for reading a dframe from a table
# tableName: name of the table
# features: a list containing the name of columns corresponding to attributes of the dframe (features of samples)
# dsn: ODBC DSN name
# npartitions: number of partitions in the dframe (it is an optional argument)
# verticaConnector: when it is TRUE (default), Vertica Connector for Distributed R will be used
# loadPolicy: it determines data loading policy of the Vertica Connector for Distributed R
db2dframe <- function(tableName, dsn, features = list(...), npartitions, verticaConnector=TRUE, loadPolicy="local") {

    if(!is.character(tableName))
        stop("The name of the table should be specified")
    if(is.null(dsn))
        stop("The ODBC DSN should be specified")
    if(!is.logical(verticaConnector))
        stop("verticaConnector can be either TRUE or FALSE")
    if(!is.character(loadPolicy))
        stop("loadPolicy can be either 'local' or 'uniform'")

    # loading vRODBC or RODBC library for master
    if (! require(vRODBC) )
        library(RODBC)

    # connecting to Vertica
    db_connect <- odbcConnect(dsn)

    #Validate table name
    table <- ""
    schema <- ""
    table_info <- unlist(strsplit(tableName, split=".", fixed=TRUE))
    if(length(table_info) > 2) {
       odbcClose(db_connect)
       stop("Invalid table name. Table name should be in format <schema_name>.<table_name>. If the table is in 'public' schema, Schema name can be ignored while specifying table name")
    } else if(length(table_info) == 2){
       schema <- table_info[1]
       table <- table_info[2]
    } else {
       table <- table_info[1]
       schema <- "public"
    }

    # get columns of the table/view
    feature_columns <- ""
    feature_data_type <- ""
    norelation <- FALSE
    relation_type <- ""
    if(missing(features) || length(features)==0 || features=="") {
      table_columns <- sqlQuery(db_connect, paste("select column_name, data_type_id from columns where table_schema ILIKE '", schema ,"' and table_name ILIKE '", table,"'", sep=""))
      if(!is.data.frame(table_columns)) {
        odbcClose(db_connect)
        stop(table_columns)
      }

      if(nrow(table_columns) == 0) {
         ## check if its a view
         view_columns <- sqlQuery(db_connect, paste("select column_name, data_type_id from view_columns where table_schema ILIKE '", schema ,"' and table_name ILIKE '", table,"'", sep=""))
         if(!is.data.frame(view_columns)) {
           odbcClose(db_connect)
           stop(view_columns)
         } 

         if(nrow(view_columns) == 0) {
           odbcClose(db_connect)
           norelation <- TRUE
           stop(paste("Table/View ", schema, ".", tableName, " does not exist", sep=""))
         } else { 
           relation_type <- "view"
           feature_columns <- view_columns[[1]] 
           feature_data_type <- view_columns[[2]]        
         }
      } else {
        relation_type <- "table"
        feature_columns <- table_columns[[1]]
        feature_data_type <- table_columns[[2]]
      }
    } else {
      # get column data types
      istable <- sqlQuery(db_connect, paste("select data_type_id from columns where table_name ILIKE '", table, "' and table_schema ILIKE '", schema, "' and lower(column_name) in (", tolower(.toColumnString(features, TRUE)), ")", sep=""))
      if(nrow(istable) == 0) {
         isview <- sqlQuery(db_connect, paste("select data_type_id from view_columns where table_name ILIKE '", table, "' and table_schema ILIKE '", schema, "' and lower(column_name) in (", tolower(.toColumnString(features, TRUE)), ")", sep=""))
         if(nrow(isview) == 0) {
           odbcClose(db_connect)
           norelation <- TRUE
           stop(paste("Table/View ", schema, ".", tableName, " does not exist with specified 'features'", sep=""))
         } else {
           relation_type <- "view"
           feature_data_type <- isview[[1]]
         }

      } else {
        relation_type <- "table"
        feature_data_type <- istable[[1]]
      }

      feature_columns <- features
    }

    # we have columns, construct column string
    nFeatures <- length(feature_columns)  # number of features
    columns <- .toColumnString(feature_columns)

    # when npartitions is not specified it should be calculated based on the number of executors
    missingNparts <- FALSE
    if(missing(npartitions)) {
        ps <- distributedR_status()
        nExecuters <- sum(ps$Inst)   # number of executors asked from distributedR
        noBlock2Exc <- 1             # ratio of block numbers to executor numbers
        npartitions <- nExecuters * noBlock2Exc  # number of partitions
        missingNparts <- TRUE
    } else {
        npartitions <- round(npartitions)
        if(npartitions <= 0) {
            odbcClose(db_connect)
            stop("npartitions should be a positive integer number.")
        }
    }

    # checking availabilty of all columns
    qryString <- paste("select", columns, "from", tableName, "limit 1")
    oneLine <- sqlQuery(db_connect, qryString)
    # check valid response from the database
    if (! is.data.frame(oneLine) ) {
        odbcClose(db_connect)
        stop(oneLine)
    }

    ## data type check
    supported_types <- list("Integer", "Boolean", "Float", "Numeric", "Char", "Varchar", "Long Varchar")     # derived from types table
    supported_type_ids <- sqlQuery(db_connect, paste("select type_id from types where type_name in (", .toColumnString(supported_types, TRUE), ")", sep=""))
    if(!all(feature_data_type %in% supported_type_ids[[1]])) {
      odbcClose(db_connect)
      stop("Only numeric, logical and character data types are supported")
    }
    

    # reading the number of observations in the table
    qryString <- paste("select count(*) from", tableName)
    nobs <- sqlQuery(db_connect, qryString)
    # check valid response from the database
    if (! is.data.frame(nobs) ) {
        odbcClose(db_connect)
        stop(nobs)
    }
    if(nobs == 0) {
        odbcClose(db_connect)
        stop("The table is empty!")
    }
    X <- FALSE

    if (verticaConnector) {
        tryCatch ({
        .checkUnsegmentedProjections(schema, table, relation_type, db_connect)

        #get projection_name           
        qryString <- paste("select projection_id, projection_name from tables t, projections p where t.table_name ILIKE '", table, "' and t.table_schema ILIKE '", schema, "'and t.table_id=p.anchor_table_id and p.is_super_projection=true and is_up_to_date=true order by projection_name limit 1", sep="")
        projection_details <- sqlQuery(db_connect, qryString);
        noprojection = FALSE
          
        if(nrow(projection_details) == 0) {
            noprojection = TRUE
        }
        else {
            projection_name <- as.character(projection_details$projection_name)
            projection_oid <- as.numeric(projection_details$projection_id)
        }
        ## Check if it a view or a system table
        if(noprojection) {
            qryString <- paste("select count(*) from views where table_name ILIKE '", table, "' and table_schema ILIKE '", schema, "'", sep="")
            isaview <- sqlQuery(db_connect, qryString)
            if(isaview > 0) {
              loadPolicy <- "uniform"
            } else
              stop(paste("Table/View", tableName, "does not exist or the table has no super projections with data.\nData loading aborted."))
        }

        nRows <- as.numeric(nobs)
        # calculate approximate split_size 
        partition_size <- ceiling(nRows/npartitions)

        #start data loader thread in distributedR
        ret <- .startDataLoader(partition_size)
        if(!ret)
            stop("Vertica Connector aborted.")

        #decide what type of loadPolicy to run
        if(as.character(loadPolicy) == "local") {
            #get metadata - vertica_nodes
            qryString <- paste("select node_name from projection_storage where projection_name = '", projection_name, "' order by node_name", sep="")
            vertica_nodes <- sqlQuery(db_connect, qryString)
            if(!is.data.frame(vertica_nodes))
              stop(paste("Error in Vertica:", paste(vertica_nodes, sep="", collapse="")))

            #get parameter string
            udx_param <- .getUDxParameterLocalStr(vertica_nodes)
            if(!udx_param$success){
              if(udx_param$error_code=="ERR02") {
                stop(udx_param$parameter_str)
              } else {
                udx_param <- .getUDxParameterUniformStr() 
                type <- "uniform"
                if(!udx_param$success) {
                  stop(udx_param$parameter_str)
                } 
              }
            } else {
              type <- "local"
            }
          } else if(as.character(loadPolicy) == "uniform") {
            udx_param <- .getUDxParameterUniformStr()
            type <- "uniform"
            if(!udx_param$success) {
              stop(udx_param$parameter_str)
            } 
          } else {
            stop(paste("Invalid data load policy selection", as.character(loadPolicy)))
          }

          #disable retry using MaxQueryRetries.
          #sqlQuery(db_connect, "select set_vertica_options('BASIC', 'DISABLE_ERROR_RETRY');")
          retries_allowed <- sqlQuery(db_connect, "select get_config_parameter('MaxQueryRetries');")
          sqlQuery(db_connect, "select set_config_parameter('MaxQueryRetries', 0);")

          #issue UDx query
          qryString <- paste("select ExportToDistributedR(", columns, " USING PARAMETERS DR_worker_info='", udx_param$parameter_str,"', DR_partition_size=", partition_size, ", data_distribution_policy='", type, "') over(PARTITION BEST) from ", tableName, sep="")

          cat("Loading total", nRows, "rows from", tableName, "from Vertica with approximate partition of", partition_size,"rows\n")
          load_result <- sqlQuery(db_connect, qryString)
          if(!is.data.frame(load_result)) {
            sqlQuery(db_connect, paste("select set_config_parameter('MaxQueryRetries', ", retries_allowed, ");"))
            error_msg <- .Call("HandleUDxError", load_result, PACKAGE="distributedR")
            stop(error_msg)
          }

          #clear retry
          #sqlQuery(db_connect, "select clr_vertica_options('BASIC', 'DISABLE_ERROR_RETRY');")
          sqlQuery(db_connect, paste("select set_config_parameter('MaxQueryRetries', ", retries_allowed, ");"))
          
          #get loader status from distributedR workers
          result <- .getLoaderResult(load_result)
          if(!is.list(result))
            stop(result)

          X <- .vertica.dframe(result, nFeatures)
          colnames(X) <- feature_columns

          }, interrupt = function(e) {}
           , error = function(e) {
             .vertica.connector(e)
          } , finally = {
             stopDataLoader()
             try({ odbcClose(db_connect)}, silent=TRUE)
          })


    # end of verticaConnector
    } else {
        # check valid number of rows based on rowid assumptions    
        qryString <- paste("select count(distinct rowid) from", tableName, "where rowid >=0 and rowid <", nobs)
        distinct_nobs <- sqlQuery(db_connect, qryString)
        if( nobs != distinct_nobs ) {
            odbcClose(db_connect)
            stop("There is something wrong with rowid. Check the assumptions about rowid column in the manual.")
        }
    
        nobs <- as.numeric(nobs)
        rowsInBlock <- ceiling(nobs/npartitions) # number of rows in each partition
  
        # creating dframe for features
        X <- dframe(dim=c(nobs, nFeatures), blocks=c(rowsInBlock,nFeatures))

        if(!missingNparts) {
            nparts <- npartitions(X)
            if(nparts != npartitions)
                warning("The number of splits changed to ", nparts)
        }

        #Load data from Vertica to dframe
        foreach(i, 1:npartitions(X), initArrays <- function(x = splits(X,i), myIdx = i, rowsInBlock = rowsInBlock, 
                nFeatures=nFeatures, tableName=tableName, dsn=dsn, columns=columns) {

            # loading RODBC for each worker
            if (! require(vRODBC) )
                library(RODBC)
        
            start <- (myIdx-1) * rowsInBlock # start row in the block, rowid starts from 0
            end <- rowsInBlock + start   # end row in the block

            qryString <- paste("select",columns, " from", tableName, "where rowid >=", start,"and rowid <", end)

            # each worker connects to Vertica to load its partition of the dframe
            connect <- -1
            tryCatch(
                {
                  connect <- odbcConnect(dsn)
                }, warning = function(war) {
                  if(connect == -1)
                    stop(war$message)
                }
            )
            segment<-sqlQuery(connect, qryString, buffsize= end-start)
            odbcClose(connect)

            x <- segment

            update(x)
        })
        odbcClose(db_connect)
        colnames(X) <- feature_columns
    } # if-else (verticaConnector)

    X
}

.toColumnString <- function(x, withQuotes=FALSE) {

   num <- length(x)
   columns <- "" 
   if(num > 1) {
      for(i in 1:(num-1)) {
          if(withQuotes)
            columns <- paste(columns,'\'', x[i], '\'', ',', sep="")
          else
            columns <- paste(columns, x[i], ',')
      }   
   }   
   if(withQuotes)
      columns <- paste(columns, '\'', x[num], '\'', sep="")
   else
      columns <- paste(columns, x[num])

   columns
}

# Example:
# loadedSamples <- db2dframe("mortgage1e4", dsn="RTest", list("mltvspline1", "mltvspline2", "agespline1", "agespline2", "hpichgspline", "ficospline"))
