export const examples = [
  { name: 'Start here', sql: `SELECT @@VERSION AS version;

SELECT value AS n, value * value AS square
FROM GENERATE_SERIES(1, 8)
ORDER BY value;` },
  { name: 'Tables & joins', sql: `DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
CREATE TABLE customers (id int PRIMARY KEY, name nvarchar(50));
CREATE TABLE orders (id int PRIMARY KEY, customer_id int REFERENCES customers(id), amount decimal(10,2));
INSERT INTO customers VALUES (1, N'Ada'), (2, N'Grace');
INSERT INTO orders VALUES (1, 1, 42.50), (2, 1, 17.25), (3, 2, 89.00);

SELECT c.name, COUNT(*) AS orders, SUM(o.amount) AS total
FROM customers c JOIN orders o ON o.customer_id = c.id
GROUP BY c.name ORDER BY total DESC;` },
  { name: 'Window functions', sql: `SELECT value AS n,
  ROW_NUMBER() OVER (ORDER BY value DESC) AS rank,
  SUM(value) OVER (ORDER BY value ROWS UNBOUNDED PRECEDING) AS running_total
FROM GENERATE_SERIES(1, 10)
ORDER BY value;` },
  { name: 'JSON', sql: `SELECT name, score
FROM OPENJSON(N'[{"name":"Ada","score":98},{"name":"Grace","score":99}]')
WITH (name nvarchar(50), score int)
ORDER BY score DESC;` },
  { name: 'Transactions', sql: `DROP TABLE IF EXISTS counter;
CREATE TABLE counter (value int);
INSERT INTO counter VALUES (1);
BEGIN TRANSACTION;
UPDATE counter SET value = 99;
SELECT value AS inside_transaction FROM counter;
ROLLBACK;
SELECT value AS after_rollback FROM counter;` },
];
