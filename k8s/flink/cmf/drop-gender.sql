-- Reads the raw JSON produced by the datagen-users connector on users, drops the
-- `gender` field and writes the result to users-redacted.
INSERT INTO `users-redacted`
SELECT `key`, ENCODE(JSON_OBJECT(
  'registertime' VALUE CAST(JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.registertime') AS BIGINT),
  'userid'       VALUE JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.userid'),
  'regionid'     VALUE JSON_VALUE(DECODE(`val`, 'UTF-8'), '$.regionid')), 'UTF-8')
FROM `users`
