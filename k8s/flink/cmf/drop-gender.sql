-- Reads the raw JSON produced by the datagen-users connector on test1, drops the
-- `gender` field and writes the result to flink-test.
INSERT INTO `flink-test`
SELECT `key`, ENCODE(JSON_OBJECT(
  'registertime' VALUE CAST(JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.registertime') AS BIGINT),
  'userid'       VALUE JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.userid'),
  'regionid'     VALUE JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.regionid')), 'UTF-8')
FROM `test1`
