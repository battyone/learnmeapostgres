-- Most succinct and most highly optimized using C extension function. But
-- still requires you to name the output types. Can be extended by messing
-- with the delimited query, such as grouping or ordering inside the
-- crosstab, so it's very flexible.

select * from crosstab(                                                        
    'select rowid, attribute, value 
     from test_crosstab'
) as ct (row_name text, att1 text, att2 text, att3 text, att4 text);


-- Verbose, but lets you do any manipulation you might need in the subquery.
-- Have to take special care of which type of join to use.
select t1.rowid, t1.att1, t2.att2, t3.att3, t4.att4 
from 
    (select rowid, value as att1 
     from test_crosstab where attribute = 'att1') t1 
left outer join 
    (select rowid, value as att2 
     from test_crosstab where attribute = 'att2') t2 
  on t1.rowid = t2.rowid 
left outer join 
    (select rowid, value as att3 
    from test_crosstab where attribute = 'att3') t3 
  on t1.rowid = t3.rowid 
left outer join 
    (select rowid, value as att4 
     from test_crosstab where attribute = 'att4') t4 
  on t1.rowid = t3.rowid;


-- Succinct, but requires a special form in which you know the pivot cells are
-- unique after grouping by the relevant column, *and* you can use some aggregate
-- function, along with a suitable dummy value, to "trick" the query into getting
-- the (assumed) solo matching value as an aggregate, in this case string concat,
-- so that it works with group by.
select 
    rowid,
    string_agg( case attribute when 'att1' then value else '' end, '') as att1,
    string_agg( case attribute when 'att2' then value else '' end, '') as att2,
    string_agg( case attribute when 'att3' then value else '' end, '') as att3,       
    string_agg( case attribute when 'att4' then value else '' end, '') as att4
from test_crosstab
group by rowid 
order by rowid;


-- Note: any of the three queries can be made polymorphic in the table name and
-- possibly columns to use for the crosstab, and thus you could dynamically query
-- for the distinct values of the pivot column, and automatically fill in the 
-- names of the output columns, for example. You would have to be willing to use
-- dynamic SQL and some of the tricks as from the random sampling example, but
-- there's no reason why you can't do it.
