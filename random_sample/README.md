# Randomly sample from arbitrary Postgres tables
## requirements
This `plpgsql` code is only tested with Postgres 9.5 -- and "tested" here means that I tried it on a wide range of example cases, but did not create a robust set of actual tests for it. Since this relies on dynamic SQL, you should be extremely careful about
potential SQL injection, and be aware that run-time errors are possible.

## install
Since this consists of only function definitions, it's sufficient to execute the provided `.sql` file in a `psql` session, for example

```sql
username=# \i /path/to/random_draw.sql
```

## usage
There are two random sampling functions, `_idx_random_select` and `_random_select`, along with one helper function `_get_col_names`. 

`get_col_names` accepts a table-typed argument (more on this below) and returns a text string containing the comma-separated list of column names for that table. This is used internally for `_random_select` to ensure that the return type is not affected by the use of `row_number` to add an on-the-fly integer column. Mostly, you should not need to directly use `_get_col_names`, though it can be interesting to play with and can be modified to create a way to exclude columns from a selection.

`_idx_random_select` creates a set of jointly uniformly sampled rows from a given input table. This function also requires a text parameter providing the name of an integer index / key column contained in the table. Optionally, you can also specify an integer limit for the number of samples to draw (default is 1000) and a real-valued parameter called `_gaps` that is explained more below. The default for `_gaps` is 1.03, representing an extra 3% margin of oversampling to deal with potential gaps in the index column. You shouldn't need to adjust the default very often.

Here's an example with some toy data I have from the IMBD actors, movies, and genres data sets:

```bash
ely=# select * from _idx_random_select(NULL::actors, 'actor_id', 5);
 actor_id |        name         
----------+---------------------
     4768 | Vanessa L. Williams
      880 | Cora Witherspoon
     4966 | Yves Lavigne
     4052 | Robert Mitchum
     4615 | Tim Conway
(5 rows)

ely=# select * from _idx_random_select(NULL::actors, 'actor_id', 5);
 actor_id |     name      
----------+---------------
     4367 | Simon Lack
      155 | Amy Robinson
     1839 | Hollye Holmes
     2880 | Leo McKern
     2083 | Jasen Fisher
(5 rows)

ely=# select * from _idx_random_select(NULL::actors, 'actor_id', 5);
 actor_id |      name       
----------+-----------------
     4004 | Ringo Starr
     4967 | Yvette Mimieux
     4665 | Tom Guiry
     1288 | Edward Asner
      160 | Anatoli Davydov
(5 rows)

```

The use of `NULL::actors` reflects the need for our input variable to have the same *table type* as the underlying table we are querying, in this case a table named `actors`. Since `NULL` can be cast as any type, this works.

The column name `'actor_id'` is supplied as the integer column on which to sample. It need not be an index or key, but if it is, it will greatly boost performance. Finally, `5` is supplied as the number of row samples to be drawn.

Much of this works exactly the same way with the companion function `_random_select` except that we no longer need to specify a column name, and the table does not need to meet any requirements at all (such as the requirement for an integer column). However, because we are sacrificing the guarantee of an integer column, this method does not make use of indices or keys on the table, and instead uses `row_number` as an on-the-fly integer column. For large tables, this could be very slow.

Here's an example of `_random_select` on a table called `genres` that has only text fields and has no key or index information.

```bash
ely=# select * from _random_select(NULL::genres, 5);
    name     | position 
-------------+----------
 Action      |        1
 Crime       |        5
 Documentary |        7
 Eastern     |        9
 Thriller    |       17
(5 rows)

ely=# select * from _random_select(NULL::genres, 5);
   name    | position 
-----------+----------
 Adventure |        2
 Disaster  |        6
 History   |       11
 SciFi     |       15
 Animation |        3
(5 rows)

ely=# select * from _random_select(NULL::genres, 5);
   name    | position 
-----------+----------
 Adventure |        2
 Drama     |        8
 Fantasy   |       10
 SciFi     |       15
 Sport     |       16
(5 rows)

```

## sources
Putting this together was essentially a process of welding together several Stack Overflow answers from a single, prolific user [Erwin Brandstetter](http://stackoverflow.com/users/939860/erwin-brandstetter). It was not easy to weld them together, and I had to add in some of my own work to refactor things. All of the work for the more generic version using `row_number` and `_get_col_names` was my own addition, so any bugs and inefficiences are my own. 

The original answers are extremely instructive. Note that the random sampling suggestion works only for a known-in-advance, fixed table name. It was precisely the generalization to accepting arbitrary table names that motivated me to pursue this.

*[Best way to select random rows PostgreSQL](http://stackoverflow.com/a/8675160/567620)

*[Refactor a PL/pgSQL function to return the output of various SELECT queries](http://stackoverflow.com/a/11751557/567620)

*[Table name as a PostgreSQL function parameter](http://stackoverflow.com/a/10711349/567620)

## more details
Internally, there are a number of interesting facts about this implementation.

### polymorphism
The functions make use of polymorphic types. For instance, the first argument to both `_idx_random_select` and `_random_select` is `_tbl` with type `anyelement`. `anyelement` is the Postgres name for any fully polymorphic data type. If you use `anyelement` for multiple input parameters, then at run-time the actual resolved type must be the same for each polymorphic input. Further, as in this case, if you specify that the function *returns* `anyelement`, then there must be at least one `anyelement` input variable, and the return type must match the actual resolved type of that input.

In our case, the polymorphic type is meant to be a table type (basically, the tuple of labeled columns and their types that defines the table's relation). Because we don't explicitly type the input variable, there are a number of unusual functions used throughout in order to induce the correct table type. 

There is `pg_typeof`, there is use of case to `regclass` and there is the format use of `%I`. 

From the Stack Overflow source above: "`pg_typeof(_tbl_type)` returns the name of the table as object identifier type `regtype`. When automatically converted to text, identifiers are automatically double-quoted and schema-qualified if needed. Therefore, SQL injection is not a possible. This can even deal with schema-qualified table-names where `quote_ident()` would fail."

The cast to `regclass` is a special short-hand notation for referencing certain [object identifier types](http://www.postgresql.org/docs/8.1/static/datatype-oid.html) that are used within system reference tables. In particular, taking a string name like `'mytable'` and casting it with `'mytable'::regclass` is essentially equivalent to saying `SELECT oid FROM pg_class WHERE relname = 'mytable'`.

Finally, the use of `format` (a powerful string formatting utility adding beginning in Postgres 9.1) is similar to string formatting with `printf` in C or in Python. However, Postgres provides the type identifier `%I` as an instruction that the parameter should be rendered as a *SQL identifier*, instead of as a string or as a literal value of some type. So when working with dynamic SQL and the need to insert a table name for purposes of a query, you'll need to occasionally use `%I` to have the same inserted as an identifier.

### recursive CTE
The functions are implemented with the use of recursive CTEs as mentioned at the Stack Overflow links. In this case, the recursive nature of the CTE is very simple: the random picker is called repeatedly until the desired number of rows is sampled. `UNION` is used to append the results of a recursive call onto whatever result set has already been built, in such a way that duplicate draws are removed. Because SQL will form the result set in a lazy manner, the overall total use of `LIMIT` to limit the result to the desired number of samples will ensure that the recursion terminates. It's the same idea as using `take` in Haskell to obtain some number of entries from an infinite list.

### `row_number`
For the more generic version, `_random_select`, no requirement is made for an integer column to serve as the basis for sampling. Instead, internal to the query, the `row_number` function is used to generate that integer column on the fly. However, by appending a new column containing the row number, it effectively changes the result set's type from whatever the table type of `_tbl` happened to be into a new table type that is just like that of `_tbl` but with an extra integer entry corresponding to the row number.

As mentioned above, polymorphic Postgres outputs won't allow this. The output `anyelement` type has to match exactly with the input `anyelement` type. Additionally, it's not desirable for the random sampler to return a new table that has an extra column. That might make it harder to pass the random sample downstream to other consumers expecting precisely the same schema as the underlying table that was sampled.

To circumvent this, an extra query is added in the `DECLARE` section that obtains the list of columns from the input `_tbl`. This string of column names is then inserted into the formatted dynamic SQL string, so that the final returned result only consists of the original columns (effectively excluding `row_number` from the selection that is returned).
 

