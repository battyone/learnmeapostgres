-- Uncomment and run if you need the extension for your database.
-- create extension tablefunc

-- Create some test data.
create table test_crosstab(id serial, rowid text, attribute text, value text);

insert into test_crosstab(rowid, attribute, value) 
values ('test1', 'att1', 'val1'), 
       ('test1', 'att2', 'val2'), 
       ('test1', 'att3', 'val3'), 
       ('test1', 'att4', 'val4'), 
       ('test2', 'att1', 'val5'), 
       ('test2', 'att2', 'val6'), 
       ('test2', 'att3', 'val7'), 
       ('test2', 'att4', 'val8');
