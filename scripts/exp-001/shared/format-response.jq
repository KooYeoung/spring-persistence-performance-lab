def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

def positive_integer:
  type == "number" and . > 0 and floor == .;

def zero_integer:
  type == "number" and . == 0 and floor == .;

def finite_positive_number:
  type == "number" and . > 0;

def abs_value:
  if . < 0 then -. else . end;

def close_to($expected; $tolerance):
  finite_positive_number and ((. - $expected) | abs_value) <= $tolerance;

def elapsed_millis_valid($record):
  ($record.elapsedMillis | close_to(($record.elapsedNanos / 1000000); 0.0000005));

def legacy_record_valid($expectedPath; $expectedCount):
  . as $record
  | type == "object"
  and (has("resultFormatVersion") | not)
  and (has("elapsedSeconds") | not)
  and ($record.path == $expectedPath)
  and ($record.inputCount | positive_integer)
  and ($record.inputCount == $expectedCount)
  and ($record.savedCount | positive_integer)
  and ($record.savedCount == $expectedCount)
  and ($record.elapsedNanos | positive_integer)
  and elapsed_millis_valid($record)
  and ($record.valid == true)
  and ($record.rowCount | positive_integer)
  and ($record.rowCount == $expectedCount)
  and ($record.distinctBusinessKeyCount | positive_integer)
  and ($record.distinctBusinessKeyCount == $expectedCount)
  and ($record.missingKeyCount | zero_integer)
  and ($record.unexpectedKeyCount | zero_integer)
  and ($record.duplicateKeyCount | zero_integer)
  and ($record.expectedChecksum | sha256_checksum)
  and ($record.actualChecksum | sha256_checksum)
  and ($record.expectedChecksum == $record.actualChecksum);

def known_response_keys:
  [
    "path",
    "inputCount",
    "savedCount",
    "elapsedNanos",
    "elapsedMillis",
    "valid",
    "rowCount",
    "distinctBusinessKeyCount",
    "missingKeyCount",
    "unexpectedKeyCount",
    "duplicateKeyCount",
    "expectedChecksum",
    "actualChecksum",
    "resultFormatVersion",
    "elapsedSeconds"
  ];

def unknown_fields:
  known_response_keys as $known
  | with_entries(select(.key as $key | ($known | index($key) | not)));

. as $raw
| if ($raw | legacy_record_valid($expectedPath; $expectedCount) | not) then
    error("raw response schema validation failed")
  else
    {
      resultFormatVersion: 2,
      path: $raw.path,
      inputCount: $raw.inputCount,
      savedCount: $raw.savedCount,
      elapsedNanos: $raw.elapsedNanos,
      elapsedSeconds: ($raw.elapsedNanos / 1000000000),
      elapsedMillis: $raw.elapsedMillis,
      valid: $raw.valid,
      rowCount: $raw.rowCount,
      distinctBusinessKeyCount: $raw.distinctBusinessKeyCount,
      missingKeyCount: $raw.missingKeyCount,
      unexpectedKeyCount: $raw.unexpectedKeyCount,
      duplicateKeyCount: $raw.duplicateKeyCount,
      expectedChecksum: $raw.expectedChecksum,
      actualChecksum: $raw.actualChecksum
    }
    + ($raw | unknown_fields)
  end
