

-- Obtain a formatted string of column names from a given table.
CREATE OR REPLACE FUNCTION _get_col_names(_tbl anyelement)
    RETURNS text AS
$func$
DECLARE
    _result text = '';
BEGIN
    _result := (
        SELECT array_to_string(
            ARRAY(SELECT '' || c.column_name 
                  FROM   information_schema.columns AS c 
                  WHERE  table_name=format('%1$I', pg_typeof(_tbl))
            ), 
        ', ')
    );
    RETURN _result;
END
$func$ LANGUAGE plpgsql;


-- Select a random subset of a table, based upon select a random
-- subsample of the table's known integer index/key column.
CREATE OR REPLACE FUNCTION _idx_random_select(_tbl anyelement,
                                              _pk_name text,
                                              _limit int = 1000, 
                                              _gaps real = 1.03)
  RETURNS SETOF anyelement AS
$func$
DECLARE
   _surplus  int := _limit * _gaps;
   _estimate int := (
       SELECT c.reltuples * _gaps
       FROM   pg_class c
       WHERE  c.oid = format('%1$I', pg_typeof(_tbl))::regclass
   );
BEGIN

   RETURN QUERY EXECUTE format('
   WITH RECURSIVE 
       random_pick AS (
           SELECT *
           FROM (
               SELECT 1 + trunc( random() * $3 )::int
               FROM   generate_series(1, $1) g
               LIMIT  $1           
           ) r ( %2$I )
           JOIN  %1$I                      
           USING ( %2$I )        

           UNION                        
           SELECT *
           FROM (
               SELECT 1 + trunc( random() * $3 )::int
               FROM   random_pick            -- just to make it recursive
               LIMIT  $2                     -- hint for query planner
           ) r ( %2$I )
           JOIN  %1$I                        -- reference to casted table name.
           USING ( %2$I )                    -- eliminate misses
       )
   SELECT *
   FROM   random_pick
   LIMIT  $2;', pg_typeof(_tbl), _pk_name)
   USING _surplus, _limit, _estimate;
END
$func$ LANGUAGE plpgsql;



-- Select a random subsample from any arbitrary table, whether or not the
-- table has an integer index/key. Note: this can be inefficient.
CREATE OR REPLACE FUNCTION _random_select(_tbl anyelement,
                                          _limit int = 1000)
    RETURNS SETOF anyelement AS
$func$
DECLARE
    _original_columns text := _get_col_names(_tbl);
BEGIN

   RETURN QUERY EXECUTE format('
   WITH RECURSIVE 
       _with_row_nums AS (
           SELECT row_number() OVER () as row_num, *
           FROM   %1$I
       ),

       random_pick AS (
           SELECT *
           FROM (
               SELECT 1 + trunc( random() * $1 )::int
               FROM   generate_series(1, $1) g
               LIMIT  $1           
           ) r1 ( row_num )
           JOIN  _with_row_nums r2                     
           USING ( row_num )        

           UNION                        
           SELECT *
           FROM (
               SELECT 1 + trunc( random() * $1 )::int
               FROM   random_pick            
               LIMIT  $1                     
           ) r1 ( row_num )
           JOIN  _with_row_nums r2
           USING ( row_num )                    
       )
   SELECT %2$s
   FROM   random_pick
   LIMIT  $1;', pg_typeof(_tbl), _original_columns)
   USING _limit;
END
$func$ LANGUAGE plpgsql;
