import Foundation

/// Errors retained from the JavaScriptCore-backed releases for source compatibility.
public enum HTMLToMarkdownError: Error, CustomStringConvertible, Sendable {
    case resourceNotFound
    case jsContextInitializationFailed
    case prettierObjectNotFound
    case formattingFailed(String)

    public var description: String {
        switch self {
        case .resourceNotFound:
            return "html-to-markdown.bundle.min.js resource not found"
        case .jsContextInitializationFailed:
            return "Failed to initialize JavaScript context"
        case .prettierObjectNotFound:
            return "HTMLToMarkdown object not found in JavaScript context"
        case .formattingFailed(let message):
            return "Conversion failed: \(message)"
        }
    }
}

/// A stateless, native Swift HTML-to-Markdown converter.
///
/// Instances are `Sendable`, and each call builds its own parser state. The same
/// instance can therefore be used from any thread or task.
public final class HTMLToMarkdown: Sendable {
    public init() throws {}

    public func conversion(_ html: String, options: [String: Any] = [:]) throws -> String {
        // The old implementation JSON-encoded this dictionary before handing it
        // to JavaScript. Preserve the resulting validation behavior.
        guard JSONSerialization.isValidJSONObject(options) else {
            throw HTMLToMarkdownError.formattingFailed(
                "The options dictionary is not valid JSON"
            )
        }

        do {
            return try NativeHTMLToMarkdown(
                options: try ConversionOptions(options)
            ).convert(html)
        } catch let error as HTMLToMarkdownError {
            throw error
        } catch {
            throw HTMLToMarkdownError.formattingFailed(String(describing: error))
        }
    }

    public func conversion(_ html: String) throws -> String {
        try conversion(html, options: [:])
    }
}

struct ConversionOptions: Sendable {
    let checked: String
    let enableAutolinkHeadings: Bool
    let fragment: Bool
    let newlines: Bool
    let quotes: [String]
    let rule: Character
    let unchecked: String

    init(_ values: [String: Any]) throws {
        checked = values["checked"] as? String ?? "[x]"
        enableAutolinkHeadings = values["enableAutolinkHeadings"].map(Self.isTruthy) ?? false
        fragment = values["fragment"].map(Self.isTruthy) ?? true
        newlines = values["newlines"].map(Self.isTruthy) ?? false
        let requestedQuotes = (values["quotes"] as? [String])?
            .filter { $0.count >= 2 } ?? []
        quotes = requestedQuotes.isEmpty ? ["\"\""] : requestedQuotes
        unchecked = values["unchecked"] as? String ?? "[ ]"

        guard let requested = values["rule"], Self.isTruthy(requested) else {
            rule = "*"
            return
        }
        if let string = requested as? String,
           string.count == 1,
           let character = string.first,
           character == "*" || character == "-" || character == "_" {
            rule = character
        } else {
            throw HTMLToMarkdownError.formattingFailed(
                "Cannot serialize rules with `\(requested)` for `options.rule`, "
                    + "expected `*`, `-`, or `_`"
            )
        }
    }

    private static func isTruthy(_ value: Any) -> Bool {
        switch value {
        case is NSNull:
            return false
        case let value as Bool:
            return value
        case let value as String:
            return !value.isEmpty
        case let value as Int:
            return value != 0
        case let value as Double:
            return value != 0 && !value.isNaN
        case let value as NSNumber:
            return value.doubleValue != 0 && !value.doubleValue.isNaN
        default:
            // JavaScript arrays and objects are truthy, including empty ones.
            return true
        }
    }
}
