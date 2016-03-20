-------------------------------------------------------------------------------
-- A set of plpgsql functions to facilitate drawing jointly uniformly        --
-- distributed subsets of rows from arbitrary PostgreSQL tables.             --
--                                                                           --
-- Author: Ely M. Spears                                                     --
-- Date: Mar. 19, 2016                                                       --
--                                                                           --
-- This code is modified from a collection of several sources, which are     --
-- documented at this code's repository:                                     --
-- < https://github.com/spearsem/learnmeapostgres/tree/master/random_sample >--
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
--| Function _get_col_names                                                  --
--  Obtain a formatted string of column names from a given table.            --
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _get_col_names(_tbl anyelement)
----------
-- _tbl: Table-typed input argument, such as `NULL::table_name`
----------
    -- Returns a text value containing a comma-separated string of
    -- the column names from input _tbl.
    RETURNS text AS
$func$
DECLARE
    _result text = ''; -- Placeholder for the output string.
BEGIN
    _result := (
 
        -- Use array_to_string to convert an array of names into a single 
        -- string
        SELECT array_to_string(

            -- Use ARRAY to convert a column of strings into an array that
            -- can be joined with a comma.
            ARRAY(
                -- This concatenates the column name with the empty string to
                -- induce conversion to text type.
                SELECT '' || c.column_name 
                FROM   information_schema.columns AS c 
                WHERE  table_name=format('%1$I', pg_typeof(_tbl))
                    -- The use of `format` above will produce a quoted string
                    -- for the table name via `pg_typeof` and the %I format
                    -- specifier which renders the argument as a SQL identifier
            ), 
        ', ') -- The comma separator for array to string.
    );
    RETURN _result;
END
$func$ LANGUAGE plpgsql;


-------------------------------------------------------------------------------
--| Function _idx_random_select                                              --
--  Randomly sample from a table based on an integer key/index column.       --
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _idx_random_select(_tbl anyelement,
                                              _pk_name text,
                                              _limit int = 1000, 
                                              _gaps real = 1.03)
----------
-- _tbl:     Table-typed input argument, such as `NULL::table_name`
-- _pk_name: String giving the column name within _tbl of an integer key column
-- _limit:   Number of randomly sampled rows desired in the output.
-- _gaps:    Over-sampling factor to correct for key column gaps, see document
--           documentation for _surplus assignment below.   
----------
    -- Return type is polymorphic table-type that must match the type of _tbl.
    RETURNS SETOF anyelement AS
$func$
BEGIN
    RETURN QUERY EXECUTE format('
    -- Define the recursive CTEs for actually creating the samples.
    WITH RECURSIVE 

        -- Assign key column min and max into local variables.
        _min_key AS (
             SELECT min(%2$I)
             FROM   %1$I
        ),
        

        _max_key AS (
            SELECT max(%2$I)
            FROM   %1$I
        ),
        
        
        -- Using computed min/max, get the key range assuming no gaps.
        _key_range as (
            SELECT (SELECT * FROM _max_key) - (SELECT * FROM _min_key)
        ),
        
        
        -- Because there might be gaps, multiply the key range by an over-
        -- sampling factor, the _gaps input. This way, each random draw over-
        -- samples to counter-act the possibility that sampling an entry in the 
        -- gaps causes that entry to be lost when joining back to the original 
        -- table, and thus would lead to fewer samples than desired. Note that 
        -- since the implementation below uses the recursive CTE trick, if 
        -- fewer samples are returned, it will repeat a recursive call and keep
        -- sampling until the limit is satisfied. So this _surplus trick is not 
        -- strictly necessary. However, if there are significantly large gaps 
        -- in the key column, then rely solely on the recursive calls will be 
        -- slow, whereas going ahead and getting an over-sampled draw, then 
        -- discarding what doesnt appear in the key column may be more 
        -- efficient. You can remove this oversampling optimization by setting 
        -- _gaps = 1.0 when you call the function.
        
        _surplus AS (
            SELECT ((SELECT * FROM _key_range) * $1)::int
        ),


        random_pick AS (

            SELECT *
            FROM (

                -- Create a random integer column that ranges between
                -- _min_key and _max_key, and has length of _surplus,
                SELECT (SELECT * FROM _min_key) + 
                       trunc(random() * (SELECT * FROM _key_range))::int
                FROM   generate_series(1, (SELECT * FROM _surplus)) g
           
            ) r ( %2$I ) -- This gives the random column the same name
                         -- as the key column, using `format` specifiers.

            -- Join the random generated integer column onto the table to
            -- sample, using the key column to ensure only valid rows from
            -- the original table are retained.
            JOIN  %1$I      -- This formats the table name via pg_typeof.                 
            USING ( %2$I )  -- This formats the key column name.     
    
            -- Do a UNION to a recursive call to the same random draw. The
            -- UNION forces uniqueness, including in the first table result
            -- above.      
            UNION      
                 
            -- Here is the recursive call to this CTE. It will not be needed
            -- any time that the above query has produced already a unique set
            -- of valid result rows that provide enough rows to meet the 
            -- _limit. But whenever there are duplicates or not enough valid
            -- rows (because of gaps in the key column), then UNION-ing with
            -- this recursive query fetches more random rows in a lazy manner
            -- until the full result set is obtained.
            SELECT *
            FROM (
                SELECT (SELECT * FROM _min_key) + 
                       trunc(random() * (SELECT * FROM _key_range))::int
                FROM   random_pick            
                LIMIT  $2                     
            ) r ( %2$I )    -- These are the same naming format specifiers as
            JOIN  %1$I      -- in the first query above.
            USING ( %2$I )
        )

    -- Finally, with the recursive CTE defined, we can simply select from it
    -- with a simple LIMIT equal to the _limit set as input argument.
    SELECT *
    FROM   random_pick
    LIMIT  $2;', pg_typeof(_tbl), _pk_name)
    USING _gaps, _limit;
END
$func$ LANGUAGE plpgsql;


-------------------------------------------------------------------------------
--| Function _random_select                                                  --
--  Randomly sample from a table                                             --
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _random_select(_tbl anyelement, _limit int = 25)
----------
-- _tbl:     Table-typed input argument, such as `NULL::table_name`
-- _limit:   Number of randomly sampled rows desired in the output.
----------
    -- Return type is polymorphic table-type that must match the type of _tbl.
    RETURNS SETOF anyelement AS
$func$
DECLARE
    -- Comma-separated string with _tbl's column names, used to ensure only the
    -- columns from _tbl are returned, to comply with the rules on polymorphic
    -- anyelement return types.
    _original_columns text := _get_col_names(_tbl);
BEGIN
   RETURN QUERY EXECUTE format('
   WITH RECURSIVE 
       -- Dynamic query to get accurate table count. Caching will mean the cost
       -- of the query should only be paid once, but still it can be slow for
       -- large, unindexed tables. You can use `reltuples` from `pg_class` for
       -- the supplied table name as a cheaper, but less accurate, size.
       _tbl_count AS ( 
           SELECT count(*) 
           FROM   %1$I
       ),


       -- Provides a CTE for a query that gets all of `_tbl` but with a new
       -- integer column containing row_number. Note that a column name must be
       -- chosen for the row_number, and this should be named in a way to avoid
       -- any conflict with other column names. I chose `the_row_num` with a
       -- random string appended to the end to make it unlikely that it 
       -- conflicts, although it is still theoretically possible.
       _with_row_nums AS (
           SELECT row_number() OVER () as the_row_num_eFgtRFds, *
           FROM   %1$I
       ),


       -- The recursive CTE query in this case is greatly simplified because no
       -- bounds or range checking, nor any gap-correcting oversampling, is 
       -- ever needed. With row_number, we are sure to get precisely the range
       -- of integers from 1 to the count of (_tbl), with no gaps possible. As
       -- a result, we can sample _limit as the number of rows directly,
       -- without any need for _surplus or _gaps.

       -- Of course, there is still the possibility of duplicates, so we still
       -- use UNION with a recursive call which will lazily produce more rows,
       -- remove duplictes, and terminate once the overall requested row limit
       -- is reached.

       random_pick AS (
           SELECT *
           FROM (
               SELECT 1 + trunc(random() * (SELECT * FROM _tbl_count))::int
               FROM   generate_series(1, (SELECT * FROM _tbl_count)) g
               LIMIT  $1                               
           ) r1 ( the_row_num_eFgtRFds )               
           JOIN  _with_row_nums r2                     
           USING ( the_row_num_eFgtRFds )
                   

           -- Same method of removing duplicates as in _idx_random_select.
           UNION                        

           -- Same method of recursive call as in _idx_random_select.           
           SELECT *
           FROM (
               SELECT 1 + trunc(random() * (SELECT * FROM _tbl_count))::int
               FROM   random_pick            
               LIMIT  $1                     
           ) r3 ( the_row_num_eFgtRFds )
           JOIN  _with_row_nums r4
           USING ( the_row_num_eFgtRFds )                    
       )

   -- This results in the same final query as for _idx_random_select, except
   -- that we must manually specify every proper column name from _tbl in the
   -- selection. Otherwise, it would include an int column named 
   -- `the_row_num_eFgtRFds`, and this would not have been part of the poly-
   -- morphic `anyelement` type from _tbl in the input argument, and thus would
   -- fail at runtime with an output type error.

   -- To solve this, the string with _tbl column names is formatted, as 
   -- non-quoted string, and placed in for the selection.
   SELECT %2$s
   FROM   random_pick
   LIMIT  $1;', pg_typeof(_tbl), _original_columns)
   USING _limit;
END
$func$ LANGUAGE plpgsql;
