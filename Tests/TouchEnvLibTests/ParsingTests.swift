import XCTest
@testable import TouchEnvLib

final class ParseEnvFileTests: XCTestCase {

    // MARK: - Basic parsing

    func testBasicKeyValue() {
        let result = parseEnvFile("FOO=bar")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    func testMultipleEntries() {
        let result = parseEnvFile("FOO=bar\nBAZ=qux")
        XCTAssertEqual(result, [
            EnvEntry(key: "FOO", value: "bar"),
            EnvEntry(key: "BAZ", value: "qux"),
        ])
    }

    func testEmptyValue() {
        let result = parseEnvFile("FOO=")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "")])
    }

    func testValueContainingEquals() {
        let result = parseEnvFile("URL=https://example.com?a=1&b=2")
        XCTAssertEqual(result, [EnvEntry(key: "URL", value: "https://example.com?a=1&b=2")])
    }

    // MARK: - Comments and blank lines

    func testSkipsComments() {
        let result = parseEnvFile("# this is a comment\nFOO=bar")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    func testSkipsInlineCommentStyleLine() {
        // Lines starting with # are skipped; inline comments are NOT supported
        // (value includes everything after =)
        let result = parseEnvFile("FOO=bar # not a comment")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar # not a comment")])
    }

    func testSkipsBlankLines() {
        let result = parseEnvFile("\n\nFOO=bar\n\n\nBAZ=qux\n")
        XCTAssertEqual(result, [
            EnvEntry(key: "FOO", value: "bar"),
            EnvEntry(key: "BAZ", value: "qux"),
        ])
    }

    func testSkipsWhitespaceOnlyLines() {
        let result = parseEnvFile("   \nFOO=bar\n  \t  ")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    func testSkipsLinesWithoutEquals() {
        let result = parseEnvFile("NOPE\nFOO=bar")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    // MARK: - Export prefix

    func testExportPrefix() {
        let result = parseEnvFile("export FOO=bar")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    func testExportWithQuotes() {
        let result = parseEnvFile("export FOO=\"bar baz\"")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar baz")])
    }

    func testExportWithExtraSpaces() {
        let result = parseEnvFile("export   FOO=bar")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "bar")])
    }

    // MARK: - Quote handling

    func testDoubleQuotedValue() {
        let result = parseEnvFile("FOO=\"hello world\"")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "hello world")])
    }

    func testSingleQuotedValue() {
        let result = parseEnvFile("FOO='hello world'")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "hello world")])
    }

    func testMismatchedQuotesNotStripped() {
        let result = parseEnvFile("FOO=\"hello'")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "\"hello'")])
    }

    func testSingleQuoteInsideDoubleQuotes() {
        let result = parseEnvFile("FOO=\"it's fine\"")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "it's fine")])
    }

    func testDoubleQuoteInsideSingleQuotes() {
        let result = parseEnvFile("FOO='say \"hello\"'")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "say \"hello\"")])
    }

    func testEmptyDoubleQuotedValue() {
        let result = parseEnvFile("FOO=\"\"")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "")])
    }

    func testEmptySingleQuotedValue() {
        let result = parseEnvFile("FOO=''")
        XCTAssertEqual(result, [EnvEntry(key: "FOO", value: "")])
    }

    // MARK: - touchenv: prefix

    func testTouchenvReference() {
        let result = parseEnvFile("API_KEY=touchenv:MY_SECRET")
        XCTAssertEqual(result, [EnvEntry(key: "API_KEY", value: "touchenv:MY_SECRET")])
    }

    func testMixedPlainAndTouchenvValues() {
        let input = """
        HOST=localhost
        PORT=3000
        API_KEY=touchenv:STAGING_KEY
        DEBUG=true
        """
        let result = parseEnvFile(input)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[2], EnvEntry(key: "API_KEY", value: "touchenv:STAGING_KEY"))
    }

    // MARK: - Edge cases

    func testEmptyInput() {
        let result = parseEnvFile("")
        XCTAssertEqual(result, [])
    }

    func testOnlyComments() {
        let result = parseEnvFile("# comment 1\n# comment 2")
        XCTAssertEqual(result, [])
    }

    func testDuplicateKeysPreserved() {
        let result = parseEnvFile("FOO=first\nFOO=second")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].value, "first")
        XCTAssertEqual(result[1].value, "second")
    }

    func testWindowsLineEndings() {
        let result = parseEnvFile("FOO=bar\r\nBAZ=qux\r\n")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], EnvEntry(key: "FOO", value: "bar"))
        XCTAssertEqual(result[1], EnvEntry(key: "BAZ", value: "qux"))
    }
}

final class StripMatchingQuotesTests: XCTestCase {

    func testDoubleQuotes() {
        XCTAssertEqual(stripMatchingQuotes("\"hello\""), "hello")
    }

    func testSingleQuotes() {
        XCTAssertEqual(stripMatchingQuotes("'hello'"), "hello")
    }

    func testMismatchedNotStripped() {
        XCTAssertEqual(stripMatchingQuotes("\"hello'"), "\"hello'")
        XCTAssertEqual(stripMatchingQuotes("'hello\""), "'hello\"")
    }

    func testUnquoted() {
        XCTAssertEqual(stripMatchingQuotes("hello"), "hello")
    }

    func testEmptyMatchingQuotes() {
        XCTAssertEqual(stripMatchingQuotes("\"\""), "")
        XCTAssertEqual(stripMatchingQuotes("''"), "")
    }

    func testSingleCharacter() {
        XCTAssertEqual(stripMatchingQuotes("\""), "\"")
        XCTAssertEqual(stripMatchingQuotes("'"), "'")
    }

    func testEmptyString() {
        XCTAssertEqual(stripMatchingQuotes(""), "")
    }

    func testQuotesInMiddle() {
        XCTAssertEqual(stripMatchingQuotes("he\"ll\"o"), "he\"ll\"o")
    }
}

final class ValidateKeychainKeyTests: XCTestCase {

    func testValidKey() {
        XCTAssertNil(validateKeychainKey("MY_SECRET_KEY"))
    }

    func testValidKeyWithSpecialChars() {
        XCTAssertNil(validateKeychainKey("my-app.prod/api-key"))
    }

    func testEmptyKey() {
        XCTAssertEqual(validateKeychainKey(""), .empty)
    }

    func testNullByteKey() {
        XCTAssertEqual(validateKeychainKey("foo\0bar"), .containsNull)
    }

    func testNullByteOnly() {
        XCTAssertEqual(validateKeychainKey("\0"), .containsNull)
    }

    func testLongKey() {
        let longKey = String(repeating: "A", count: 1000)
        XCTAssertNil(validateKeychainKey(longKey))
    }

    func testUnicodeKey() {
        XCTAssertNil(validateKeychainKey("secret_key_"))
    }
}
