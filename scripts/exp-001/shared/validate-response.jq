def sha256_checksum:
  type == "string" and test("^[0-9a-f]{64}$");

type == "object"
and (.path == $expectedPath)
and ((.inputCount | type == "number") and (.inputCount == $expectedCount))
and ((.savedCount | type == "number") and (.savedCount == $expectedCount))
and ((.elapsedNanos | type == "number") and (.elapsedNanos > 0))
and (.valid == true)
and ((.rowCount | type == "number") and (.rowCount == $expectedCount))
and ((.distinctBusinessKeyCount | type == "number") and (.distinctBusinessKeyCount == $expectedCount))
and ((.missingKeyCount | type == "number") and (.missingKeyCount == 0))
and ((.unexpectedKeyCount | type == "number") and (.unexpectedKeyCount == 0))
and ((.duplicateKeyCount | type == "number") and (.duplicateKeyCount == 0))
and (.expectedChecksum | sha256_checksum)
and (.actualChecksum | sha256_checksum)
and (.expectedChecksum == .actualChecksum)
