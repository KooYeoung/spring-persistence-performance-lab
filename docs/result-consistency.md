# Result Consistency

The consistency verifier is read-only and uses a JDBC projection of the synthetic table.

It verifies:

- total row count
- distinct business key count
- missing expected business keys
- unexpected business keys
- duplicate business keys
- normalized row snapshot
- SHA-256 checksum

The normalized checksum includes:

- `businessKey`
- `name`
- `numericValue`
- `occurredOn`

The normalized checksum excludes:

- `id`
- `createdAt`

Rows are sorted by `businessKey` ascending. Text is encoded as UTF-8. Null values use the fixed field encoding `-1:`. Non-null fields are encoded as `<UTF-8 byte length>:<value>`. `occurredOn` uses `ISO_LOCAL_DATE`. `numericValue` is formatted as a plain string with scale 4. Columns use a fixed delimiter and rows use `\n`. The final checksum is lowercase hexadecimal SHA-256.

If two persistence paths have the same row count and business key set but different checksums, consistency verification fails.
