import Foundation
import SwiftSoup

indirect enum HTMLNode: Sendable {
    case text(String)
    case comment(String)
    case element(name: String, attributes: [String: String], children: [HTMLNode])

    var elementName: String? {
        guard case .element(let name, _, _) = self else { return nil }
        return name
    }

    var children: [HTMLNode] {
        guard case .element(_, _, let children) = self else { return [] }
        return children
    }

    func attribute(_ name: String) -> String? {
        guard case .element(_, let attributes, _) = self else { return nil }
        return attributes[name]
    }

}

enum HTMLDocument {
    private static let capturedAttributes = [
        "align", "alt", "checked", "class", "colspan", "disabled", "href", "id",
        "data-mdast", "label", "list", "multiple", "open", "placeholder", "poster",
        "rowspan", "selected", "src", "start", "title", "type", "value"
    ]

    static func parse(_ html: String, fragment: Bool) throws -> [HTMLNode] {
        let document = fragment
            ? try SwiftSoup.parseBodyFragment(html)
            : try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        guard let body = document.body() else { return [] }

        let firstBase = try document.select("base").first()
        let baseURL: URL?
        if let firstBase, firstBase.hasAttr("href") {
            baseURL = URL(string: try firstBase.attr("href"))
        } else {
            baseURL = nil
        }

        var ignoring = false
        return try nodes(
            from: body.getChildNodes(),
            ignoring: &ignoring,
            baseURL: baseURL
        )
    }

    private static func nodes(
        from source: [Node],
        ignoring: inout Bool,
        baseURL: URL?
    ) throws -> [HTMLNode] {
        var result: [HTMLNode] = []

        for node in source {
            if let comment = node as? Comment {
                switch comment.getData().trimmingCharacters(in: .whitespacesAndNewlines) {
                case "rehype:ignore:start":
                    ignoring = true
                case "rehype:ignore:end":
                    ignoring = false
                default:
                    if !ignoring {
                        result.append(.comment(comment.getData()))
                    }
                }
                continue
            }

            if ignoring {
                // Still inspect descendants for an end marker: ignore markers
                // may legally span element boundaries.
                _ = try nodes(
                    from: node.getChildNodes(),
                    ignoring: &ignoring,
                    baseURL: baseURL
                )
                continue
            }

            if let text = node as? TextNode {
                result.append(.text(text.getWholeText()))
                continue
            }

            guard let element = node as? Element else { continue }
            var attributes: [String: String] = [:]
            for name in capturedAttributes where element.hasAttr(name) {
                let value = try element.attr(name)
                if (name == "href" || name == "src"),
                   !value.isEmpty,
                   let baseURL,
                   let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL {
                    attributes[name] = resolved.absoluteString
                } else {
                    attributes[name] = value
                }
            }
            if attributes["data-mdast"]?.lowercased() == "ignore" {
                result.append(
                    .element(name: "#ignored", attributes: [:], children: [])
                )
                continue
            }
            let elementName = element.tagNameNormal()
            if elementName == "xmp" {
                attributes["__rawText"] = try element.html()
            }
            let children = try nodes(
                from: element.getChildNodes(),
                ignoring: &ignoring,
                baseURL: baseURL
            )
            result.append(
                .element(
                    name: elementName,
                    attributes: attributes,
                    children: children
                )
            )
        }

        return result
    }
}
