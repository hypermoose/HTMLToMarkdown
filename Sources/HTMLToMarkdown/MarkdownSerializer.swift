import Foundation

struct MarkdownSerializer {
    let options: ConversionOptions
    private var usedSlugs: [String: Int] = [:]

    init(options: ConversionOptions) {
        self.options = options
    }

    mutating func serialize(_ blocks: [MarkdownBlock]) -> String {
        let value = renderBlocks(blocks)
        return value.isEmpty ? "" : value + "\n"
    }

    private mutating func renderBlocks(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { render($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private mutating func render(_ block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let children):
            return renderInline(children)

        case .heading(let level, let children, let existingID):
            var content = children
            if options.enableAutolinkHeadings {
                let id = existingID ?? uniqueSlug(for: plainText(children))
                content.insert(
                    .link(destination: "#\(id)", title: nil, children: []),
                    at: 0
                )
            }
            let marker = String(repeating: "#", count: level)
            var rendered = renderInline(content)
            if level <= 2, rendered.contains("\n") {
                let finalLine = rendered.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).last.map(String.init) ?? ""
                let visibleFinalLine = finalLine.hasSuffix("\\")
                    ? String(finalLine.dropLast())
                    : finalLine
                let underline = String(
                    repeating: level == 1 ? "=" : "-",
                    count: max(1, visibleFinalLine.utf16.count)
                )
                return rendered + "\n" + underline
            }
            if level > 2 {
                rendered = rendered.replacingOccurrences(of: "\\\n", with: " ")
                    .replacingOccurrences(of: "\n", with: "&#xA;")
            }
            return rendered.isEmpty ? marker : marker + " " + rendered

        case .blockquote(let children):
            return renderBlocks(children)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")

        case .list(let ordered, let start, let items, let loose):
            return renderList(ordered: ordered, start: start, items: items, loose: loose)

        case .code(let language, let value):
            let longestRun = longestBacktickRun(in: value)
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            let info = language.map { sanitizeInfoString($0) } ?? ""
            if value.isEmpty {
                return "\(fence)\(info)\n\(fence)"
            }
            return "\(fence)\(info)\n\(value)\n\(fence)"

        case .thematicBreak:
            return String(repeating: String(options.rule), count: 3)

        case .table(let table):
            return renderTable(table)
        }
    }

    private mutating func renderList(
        ordered: Bool,
        start: Int,
        items: [MarkdownListItem],
        loose: Bool
    ) -> String {
        var renderedItems: [String] = []
        for (offset, item) in items.enumerated() {
            let marker = ordered ? "\(start + offset). " : "* "
            var pieces = item.blocks.map { render($0) }
            if let checked = item.checked {
                let checkbox = checked ? "[x] " : "[ ] "
                if pieces.isEmpty {
                    pieces = [checkbox.trimmingTrailingASCIIWhitespace()]
                } else {
                    pieces[0] = checkbox + pieces[0]
                }
            }

            let itemSeparator = loose || item.loose ? "\n\n" : "\n"
            let body = pieces.joined(separator: itemSeparator)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let continuation = String(repeating: " ", count: marker.count)
            let rendered = lines.enumerated().map { index, line in
                if index == 0 {
                    return line.isEmpty ? String(marker.dropLast()) : marker + line
                }
                return line.isEmpty ? "" : continuation + line
            }.joined(separator: "\n")
            renderedItems.append(rendered)
        }
        return renderedItems.joined(separator: loose ? "\n\n" : "\n")
    }

    private mutating func renderTable(_ table: MarkdownTable) -> String {
        let columnCount = table.header.count
        guard columnCount > 0 else { return "" }

        func tableInline(_ values: [MarkdownInline]) -> String {
            renderInline(values, inTable: true)
                .replacingOccurrences(
                    of: "\n",
                    with: options.newlines ? "&#xA;" : " "
                )
        }

        let header = table.header.map(tableInline)
        let rows = table.rows.map { $0.map(tableInline) }
        var widths = (0..<columnCount).map { index in
            switch table.alignments[safe: index] ?? nil {
            case .center: return 3
            case .left, .right: return 2
            case nil: return 1
            }
        }
        for column in 0..<columnCount {
            widths[column] = max(widths[column], markdownLength(header[column]))
            for row in rows where column < row.count {
                widths[column] = max(widths[column], markdownLength(row[column]))
            }
        }

        func padded(_ value: String, column: Int) -> String {
            let missing = max(0, widths[column] - markdownLength(value))
            switch table.alignments[safe: column] ?? nil {
            case .right:
                return String(repeating: " ", count: missing) + value
            case .center:
                let left = (missing + 1) / 2
                return String(repeating: " ", count: left)
                    + value
                    + String(repeating: " ", count: missing - left)
            case .left, nil:
                return value + String(repeating: " ", count: missing)
            }
        }

        func row(_ values: [String]) -> String {
            let cells = (0..<columnCount).map { index in
                padded(index < values.count ? values[index] : "", column: index)
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }

        let delimiter = (0..<columnCount).map { index -> String in
            let width = widths[index]
            switch table.alignments[safe: index] ?? nil {
            case .left:
                return ":" + String(repeating: "-", count: max(2, width - 1))
            case .center:
                return ":" + String(repeating: "-", count: max(1, width - 2)) + ":"
            case .right:
                return String(repeating: "-", count: max(2, width - 1)) + ":"
            case nil:
                return String(repeating: "-", count: width)
            }
        }

        return ([row(header), row(delimiter)] + rows.map(row)).joined(separator: "\n")
    }

    private func renderInline(
        _ values: [MarkdownInline],
        inTable: Bool = false,
        inLinkLabel: Bool = false
    ) -> String {
        var result = ""
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text):
                result += escapeText(
                    text,
                    atLineStart: index == 0 || result.hasSuffix("\n"),
                    inTable: inTable,
                    inLinkLabel: inLinkLabel
                )

            case .emphasis(let children):
                result += "*" + renderInline(
                    children,
                    inTable: inTable,
                    inLinkLabel: inLinkLabel
                ) + "*"

            case .strong(let children):
                result += "**" + renderInline(
                    children,
                    inTable: inTable,
                    inLinkLabel: inLinkLabel
                ) + "**"

            case .deletion(let children):
                result += "~~" + renderInline(
                    children,
                    inTable: inTable,
                    inLinkLabel: inLinkLabel
                ) + "~~"

            case .code(let code):
                result += renderInlineCode(code)

            case .link(let destination, let title, let children):
                let label = renderInline(
                    children,
                    inTable: inTable,
                    inLinkLabel: true
                )
                if title == nil, let autolink = autolink(
                    destination: destination,
                    label: plainText(children)
                ) {
                    result += "<\(autolink)>"
                } else {
                    result += "[\(label)](\(renderDestination(destination))"
                    if let title {
                        result += " \"\(escapeTitle(title))\""
                    }
                    result += ")"
                }

            case .image(let source, let title, let alt):
                result += "![\(escapeLabel(alt))](\(renderDestination(source))"
                if let title {
                    result += " \"\(escapeTitle(title))\""
                }
                result += ")"

            case .rawHTML(let html):
                result += html

            case .lineBreak:
                result += inTable ? " " : "\\\n"
            }
        }
        return result
    }

    private func escapeText(
        _ value: String,
        atLineStart: Bool,
        inTable: Bool,
        inLinkLabel: Bool
    ) -> String {
        var result = value
        result = result.replacingOccurrences(of: "*", with: "\\*")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        result = result.replacingOccurrences(of: "[", with: "\\[")
        result = result.replacingOccurrences(of: "<", with: "\\<")
        result = result.replacingOccurrences(of: "~", with: "\\~")
        result = result.replacingOccurrences(of: "`", with: "\\`")
        if !inLinkLabel {
            result = result.replacingOccurrences(
                of: #"(?i)\b(https?|ftp):(?=//)"#,
                with: "$1\\\\:",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"(?i)\bwww\."#,
                with: "www\\\\.",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: #"(?<=\w)@(?=[\w.-]+\.[A-Za-z])"#,
                with: "\\\\@",
                options: .regularExpression
            )
        }
        if inTable {
            result = result.replacingOccurrences(of: "|", with: "\\|")
        }

        if atLineStart {
            if result.hasPrefix("#")
                || result.hasPrefix(">")
                || result.hasPrefix("- ")
                || result.hasPrefix("+ ")
                || result.hasPrefix("* ") {
                result.insert("\\", at: result.startIndex)
            } else if result.range(
                of: #"^\d+[.)]\s"#,
                options: .regularExpression
            ) != nil,
                let whitespace = result.firstIndex(where: \.isWhitespace) {
                result.insert("\\", at: result.index(before: whitespace))
            }
        }
        return result
    }

    private func markdownLength(_ value: String) -> Int {
        // remark-gfm's default table sizing uses JavaScript string length,
        // which counts UTF-16 code units.
        value.utf16.count
    }

    private func renderInlineCode(_ value: String) -> String {
        let delimiter = String(
            repeating: "`",
            count: max(1, longestBacktickRun(in: value) + 1)
        )
        let needsPadding = value.hasPrefix("`")
            || value.hasSuffix("`")
            || (value.hasPrefix(" ") && value.hasSuffix(" ") && !value.allSatisfy(\.isWhitespace))
        return needsPadding
            ? delimiter + " " + value + " " + delimiter
            : delimiter + value + delimiter
    }

    private func longestBacktickRun(in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func sanitizeInfoString(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func renderDestination(_ value: String) -> String {
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }) {
            return "<" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ">", with: "\\>") + ">"
        }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private func escapeTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func escapeLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func autolink(destination: String, label: String) -> String? {
        if (destination.hasPrefix("http://") || destination.hasPrefix("https://")),
           destination == label {
            return destination
        }
        if destination.hasPrefix("mailto:"),
           String(destination.dropFirst("mailto:".count)) == label {
            return label
        }
        return nil
    }

    private func plainText(_ values: [MarkdownInline]) -> String {
        values.map { value in
            switch value {
            case .text(let text), .code(let text):
                return text
            case .emphasis(let children), .strong(let children), .deletion(let children):
                return plainText(children)
            case .link(_, _, let children):
                return plainText(children)
            case .image(_, _, let alt):
                return alt
            case .rawHTML:
                return ""
            case .lineBreak:
                return " "
            }
        }.joined()
    }

    private mutating func uniqueSlug(for value: String) -> String {
        let base = slug(value)
        let occurrence = usedSlugs[base, default: 0]
        usedSlugs[base] = occurrence + 1
        return occurrence == 0 ? base : "\(base)-\(occurrence)"
    }

    private func slug(_ value: String) -> String {
        var result = ""
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append("-")
            } else if scalar == "-" || scalar == "_"
                || CharacterSet.alphanumerics.contains(scalar)
                || scalar.value > 0x7F && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    func trimmingTrailingASCIIWhitespace() -> String {
        String(reversed().drop(while: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }).reversed())
    }
}
