import SwiftUI

/// A small Swift tokenizer, enough to colour the code this app generates.
enum SwiftHighlighter {
    enum Kind: Sendable, Equatable {
        case plain, keyword, type, string, number, method
    }

    struct Token: Sendable, Equatable {
        var text: String
        var kind: Kind
    }

    private static let keywords: Set<String> = [
        "import", "struct", "var", "let", "some", "func", "return", "in", "if", "else", "true", "false", "nil",
    ]

    static func tokens(in line: String) -> [Token] {
        let characters = Array(line)
        var tokens: [Token] = []
        var index = 0

        func append(_ text: String, _ kind: Kind) {
            if kind == .plain, let last = tokens.last, last.kind == .plain {
                tokens[tokens.count - 1].text += text
            } else {
                tokens.append(Token(text: text, kind: kind))
            }
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                var end = index + 1
                while end < characters.count, characters[end] != "\"" {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, characters.count)
                append(String(characters[index..<end]), .string)
                index = end
            } else if character.isNumber {
                var end = index
                while end < characters.count,
                      characters[end].isNumber
                        || (characters[end] == "." && end + 1 < characters.count && characters[end + 1].isNumber) {
                    end += 1
                }
                append(String(characters[index..<end]), .number)
                index = end
            } else if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                let word = String(characters[index..<end])
                let followsDot = index > 0 && characters[index - 1] == "."
                let isCalled = end < characters.count && characters[end] == "("
                let kind: Kind = if keywords.contains(word), !followsDot {
                    .keyword
                } else if word.first?.isUppercase == true {
                    .type
                } else if followsDot, isCalled {
                    .method
                } else {
                    .plain
                }
                append(word, kind)
                index = end
            } else {
                append(String(character), .plain)
                index += 1
            }
        }
        return tokens
    }

    static func attributed(_ line: String) -> AttributedString {
        var result = AttributedString()
        for token in tokens(in: line) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = color(for: token.kind)
            result += piece
        }
        return result
    }

    private static func color(for kind: Kind) -> Color {
        switch kind {
        case .plain: Theme.codePlain
        case .keyword: Theme.codeKeyword
        case .type: Theme.codeType
        case .string: Theme.codeString
        case .number: Theme.codeNumber
        case .method: Theme.codeMethod
        }
    }
}
