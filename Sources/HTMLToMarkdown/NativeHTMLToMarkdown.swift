import Foundation

struct NativeHTMLToMarkdown {
    let options: ConversionOptions

    func convert(_ html: String) throws -> String {
        let nodes = try HTMLDocument.parse(html, fragment: options.fragment)
        var builder = MarkdownBuilder(nodes: nodes, options: options)
        let blocks = builder.blocks(from: nodes)
        var serializer = MarkdownSerializer(options: options)
        return serializer.serialize(blocks)
    }
}

struct MarkdownBuilder {
    private enum ImplicitMergeBoundary {
        case singleSpace
        case twoSpaces
        case trailingSpaceInsideLink
    }

    private struct FormChoice {
        let value: String
        let label: String
        let selected: Bool
        let disabled: Bool
    }

    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details",
        "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup",
        "hr", "listing", "main", "nav", "ol", "p", "plaintext", "pre",
        "section", "summary", "table", "ul", "xmp"
    ]

    private static let discardedElements: Set<String> = [
        "applet", "base", "datalist", "dialog", "embed", "frame", "frameset",
        "head", "link", "math", "menu", "meta", "noembed", "noframes",
        "script", "style", "svg", "template", "title"
    ]
    private static let discardedBlockElements: Set<String> = ["dialog", "menu"]

    private var datalists: [String: [FormChoice]] = [:]
    private let options: ConversionOptions
    private var quoteDepth = 0
    private var suppressTaskCheckboxes = false
    private var suppressImplicitMediaSpacing = false

    init(nodes: [HTMLNode], options: ConversionOptions) {
        self.options = options
        collectDatalists(in: nodes)
    }

    mutating func blocks(from nodes: [HTMLNode]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var pendingInline: [MarkdownInline] = []
        var pendingMergeBoundary: ImplicitMergeBoundary?

        func appendParagraph(
            _ content: [MarkdownInline],
            merging boundary: ImplicitMergeBoundary?
        ) {
            if let boundary,
               case .paragraph(let previous)? = result.last {
                let combined: [MarkdownInline]
                switch boundary {
                case .singleSpace:
                    combined = previous + [.text(" ")] + content
                case .twoSpaces:
                    combined = previous + [.rawHTML(" "), .text(" ")] + content
                case .trailingSpaceInsideLink:
                    combined = addingTrailingSpaceInsideFinalLink(previous)
                        + content
                }
                result[result.count - 1] = .paragraph(
                    normalize(combined)
                )
            } else {
                result.append(.paragraph(content))
            }
        }

        func flushInline(merging boundary: ImplicitMergeBoundary? = nil) {
            let normalized = normalize(pendingInline)
            if !normalized.isEmpty {
                appendParagraph(normalized, merging: boundary)
            }
            pendingInline.removeAll(keepingCapacity: true)
        }

        for node in nodes {
            guard case .element(let name, _, _) = node else {
                pendingInline.append(contentsOf: inline(from: node))
                continue
            }

            if Self.discardedElements.contains(name) {
                if Self.discardedBlockElements.contains(name) {
                    flushInline(merging: pendingMergeBoundary)
                    pendingMergeBoundary = nil
                }
                continue
            }

            if Self.blockElements.contains(name) {
                flushInline(merging: pendingMergeBoundary)
                pendingMergeBoundary = nil
                result.append(contentsOf: block(from: node))
            } else if containsBlockElement(node) {
                let hadPendingInline = !normalize(pendingInline).isEmpty
                let mergeFirstParagraph = hadPendingInline
                flushInline(merging: pendingMergeBoundary)

                let generated = block(from: node)
                for (index, generatedBlock) in generated.enumerated() {
                    if index == 0,
                       mergeFirstParagraph,
                       case .paragraph(let content) = generatedBlock {
                        appendParagraph(content, merging: .singleSpace)
                    } else {
                        result.append(generatedBlock)
                    }
                }
                if case .paragraph? = generated.last {
                    if childrenEndInHTMLWhitespace(node.children) {
                        pendingMergeBoundary = name == "a"
                            ? .trailingSpaceInsideLink
                            : .twoSpaces
                    } else {
                        pendingMergeBoundary = .singleSpace
                    }
                } else {
                    pendingMergeBoundary = nil
                }
            } else {
                pendingInline.append(contentsOf: inline(from: node))
            }
        }
        flushInline(merging: pendingMergeBoundary)
        return result
    }

    private func addingTrailingSpaceInsideFinalLink(
        _ values: [MarkdownInline]
    ) -> [MarkdownInline] {
        guard case .link(let destination, let title, let children)? = values.last else {
            return values + [.text(" ")]
        }
        var result = values
        result[result.count - 1] = .link(
            destination: destination,
            title: title,
            children: children + [.text(" ")]
        )
        return result
    }

    private func childrenEndInHTMLWhitespace(_ nodes: [HTMLNode]) -> Bool {
        guard let last = nodes.last else { return false }
        switch last {
        case .text(let value):
            return value.last?.isWhitespace == true
        case .comment:
            return false
        case .element(_, _, let children):
            return childrenEndInHTMLWhitespace(children)
        }
    }

    private mutating func block(from node: HTMLNode) -> [MarkdownBlock] {
        guard case .element(let name, let attributes, let children) = node else {
            let content = normalize(inline(from: node))
            return content.isEmpty ? [] : [.paragraph(content)]
        }

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let content = normalize(inline(from: children))
            return [.heading(level: level, children: content, id: attributes["id"])]

        case "p", "summary":
            let content = normalize(inline(from: children))
            return content.isEmpty ? [] : [.paragraph(content)]

        case "blockquote":
            let content = blocks(from: children)
            return content.isEmpty ? [] : [.blockquote(content)]

        case "ul", "dir":
            return makeList(node, ordered: false)

        case "ol":
            return makeList(node, ordered: true)

        case "pre", "listing", "plaintext", "xmp":
            return [makeCodeBlock(node, preserveMarkup: name == "xmp")]

        case "hr":
            return [.thematicBreak]

        case "table":
            if let table = makeTable(node) {
                return [.table(table)]
            }
            return blocks(from: children)

        case "dl":
            return makeDescriptionList(children)

        case "a":
            let destination = attributes["href"] ?? ""
            let title = nonempty(attributes["title"])
            return wrapInlineContent(in: blocks(from: children)) { content in
                [
                    .link(
                        destination: destination,
                        title: title,
                        children: content
                    )
                ]
            }

        case "del", "s", "strike":
            return wrapInlineContent(in: blocks(from: children)) {
                [.deletion($0)]
            }

        case "canvas":
            return blocks(from: children)

        default:
            return blocks(from: children)
        }
    }

    private mutating func makeList(
        _ node: HTMLNode,
        ordered: Bool
    ) -> [MarkdownBlock] {
        let start = ordered ? max(1, Int(node.attribute("start") ?? "") ?? 1) : 1
        let listNodes = node.children.filter { $0.elementName == "li" }
        if listNodes.isEmpty {
            let nested = blocks(from: node.children)
            guard !nested.isEmpty else { return [] }
            return [
                .list(
                    ordered: ordered,
                    start: start,
                    items: [
                        MarkdownListItem(
                            blocks: nested,
                            checked: nil,
                            loose: false
                        )
                    ],
                    loose: false
                )
            ]
        }

        var items: [MarkdownListItem] = []
        for listNode in listNodes {
            var checked = checkboxState(in: listNode)
            let loose = listItemIsLoose(listNode)
            let previousSuppression = suppressTaskCheckboxes
            suppressTaskCheckboxes = checked != nil
            var itemBlocks = blocks(from: listNode.children)
            suppressTaskCheckboxes = previousSuppression
            if itemBlocks.allSatisfy(\.isEmptyParagraph) {
                checked = nil
            }
            if itemBlocks.isEmpty {
                itemBlocks = [.paragraph([])]
            }
            items.append(
                MarkdownListItem(blocks: itemBlocks, checked: checked, loose: loose)
            )
        }
        let loose = items.contains(where: \.loose)
        return [.list(ordered: ordered, start: start, items: items, loose: loose)]
    }

    private func checkboxState(in node: HTMLNode) -> Bool? {
        switch node {
        case .text, .comment:
            return nil
        case .element(let name, let attributes, let children):
            if name == "input", attributes["type"]?.lowercased() == "checkbox" {
                return attributes["checked"] != nil
            }
            for child in children {
                if let result = checkboxState(in: child) {
                    return result
                }
            }
            return nil
        }
    }

    private func listItemIsLoose(_ node: HTMLNode) -> Bool {
        let children = node.children
        if children.contains(where: { containsElement(named: "p", in: $0) }) {
            return true
        }

        for (index, child) in children.enumerated()
        where child.elementName == "ul" || child.elementName == "ol" {
            if index > 0, case .text(let text) = children[index - 1], text.contains("\n") {
                return true
            }
            if index + 1 < children.count,
               case .text(let text) = children[index + 1],
               text.contains("\n") {
                return true
            }
        }
        return false
    }

    private func makeCodeBlock(
        _ node: HTMLNode,
        preserveMarkup: Bool = false
    ) -> MarkdownBlock {
        let significantChildren = node.children.filter { child in
            if case .text(let value) = child {
                return !value.trimmingASCIIWhitespace().isEmpty
            }
            return true
        }
        let codeElement: HTMLNode?
        if significantChildren.count == 1,
           significantChildren[0].elementName == "code" {
            codeElement = significantChildren[0]
        } else {
            codeElement = nil
        }
        let languageSource = codeElement ?? node
        let language = languageSource.attribute("class")?
            .split(whereSeparator: \.isWhitespace)
            .lazy
            .compactMap { token -> String? in
                if token.hasPrefix("language-") {
                    return String(token.dropFirst("language-".count))
                }
                if token.hasPrefix("lang-") {
                    return String(token.dropFirst("lang-".count))
                }
                return nil
            }
            .first

        let sourceNodes = codeElement?.children ?? node.children
        var value = preserveMarkup
            ? node.attribute("__rawText") ?? rawText(in: sourceNodes)
            : preformattedText(in: sourceNodes)
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        while value.hasSuffix("\n") {
            value.removeLast()
        }
        return .code(language: language, value: value)
    }

    private mutating func makeTable(_ node: HTMLNode) -> MarkdownTable? {
        struct Row {
            var cells: [HTMLNode]
            var isHeader: Bool
        }

        let emptyCell = HTMLNode.element(name: "td", attributes: [:], children: [])
        var rows: [Row] = []
        var pendingComments: [HTMLNode] = []

        func cell(
            _ source: HTMLNode,
            prepending prefix: [HTMLNode] = [],
            appending suffix: [HTMLNode] = []
        ) -> HTMLNode {
            guard case .element(let name, let attributes, let children) = source else {
                return source
            }
            return .element(
                name: name,
                attributes: attributes,
                children: prefix + children + suffix
            )
        }

        func isComment(_ node: HTMLNode) -> Bool {
            if case .comment = node {
                return true
            }
            return false
        }

        func collect(_ nodes: [HTMLNode], inHeader: Bool) {
            for child in nodes {
                if isComment(child) {
                    pendingComments.append(child)
                    continue
                }
                guard case .element(let name, _, let children) = child else { continue }
                if name == "tr" {
                    var cells: [HTMLNode] = []
                    var rowComments = pendingComments
                    pendingComments.removeAll(keepingCapacity: true)

                    for rowChild in children {
                        if isComment(rowChild) {
                            rowComments.append(rowChild)
                        } else if rowChild.elementName == "th" || rowChild.elementName == "td" {
                            cells.append(cell(rowChild, prepending: rowComments))
                            rowComments.removeAll(keepingCapacity: true)
                        }
                    }
                    if !rowComments.isEmpty {
                        if let last = cells.indices.last {
                            cells[last] = cell(cells[last], appending: rowComments)
                        } else {
                            cells = [
                                .element(
                                    name: "td",
                                    attributes: [:],
                                    children: rowComments
                                )
                            ]
                        }
                    }
                    rows.append(
                        Row(
                            cells: cells,
                            isHeader: inHeader || cells.contains { $0.elementName == "th" }
                        )
                    )
                } else if name == "thead" || name == "tbody" || name == "tfoot" {
                    collect(children, inHeader: inHeader || name == "thead")
                }
            }
        }
        collect(node.children, inHeader: false)
        if !pendingComments.isEmpty, let row = rows.indices.last {
            if let last = rows[row].cells.indices.last {
                rows[row].cells[last] = cell(
                    rows[row].cells[last],
                    appending: pendingComments
                )
            } else {
                rows[row].cells = [
                    .element(
                        name: "td",
                        attributes: [:],
                        children: pendingComments
                    )
                ]
            }
        }
        if rows.isEmpty {
            return MarkdownTable(
                header: [[]],
                rows: [],
                alignments: [nil]
            )
        }

        var occupiedColumns: [Int: Int] = [:]
        for rowIndex in rows.indices {
            let sourceCells = rows[rowIndex].cells
            var expanded: [HTMLNode] = []
            var column = 0

            func consumeOccupiedColumns() {
                while let remaining = occupiedColumns[column], remaining > 0 {
                    expanded.append(emptyCell)
                    if remaining == 1 {
                        occupiedColumns[column] = nil
                    } else {
                        occupiedColumns[column] = remaining - 1
                    }
                    column += 1
                }
            }

            for cell in sourceCells {
                consumeOccupiedColumns()
                let columnSpan = max(1, Int(cell.attribute("colspan") ?? "") ?? 1)
                let rowSpan = max(1, Int(cell.attribute("rowspan") ?? "") ?? 1)
                expanded.append(cell)
                if columnSpan > 1 {
                    expanded.append(contentsOf: repeatElement(emptyCell, count: columnSpan - 1))
                }
                if rowSpan > 1 {
                    for spannedColumn in column..<(column + columnSpan) {
                        occupiedColumns[spannedColumn] = rowSpan - 1
                    }
                }
                column += columnSpan
            }

            if let finalOccupiedColumn = occupiedColumns.keys.max() {
                while column <= finalOccupiedColumn {
                    if let remaining = occupiedColumns[column], remaining > 0 {
                        expanded.append(emptyCell)
                        if remaining == 1 {
                            occupiedColumns[column] = nil
                        } else {
                            occupiedColumns[column] = remaining - 1
                        }
                    } else {
                        expanded.append(emptyCell)
                    }
                    column += 1
                }
            }
            if expanded.isEmpty {
                expanded = [emptyCell]
            }
            rows[rowIndex].cells = expanded
        }

        let columnCount = rows.map(\.cells.count).max() ?? 0
        guard columnCount > 0 else { return nil }

        let hasHeader = rows[0].isHeader
        let headerRow = hasHeader ? rows.removeFirst() : Row(cells: [], isHeader: true)
        let alignmentCells = hasHeader ? headerRow.cells : rows.first?.cells ?? []
        var alignments = Array<TableAlignment?>(repeating: nil, count: columnCount)
        var header = Array(repeating: [MarkdownInline](), count: columnCount)

        for index in 0..<min(columnCount, headerRow.cells.count) {
            header[index] = normalize(inline(from: headerRow.cells[index].children))
            switch headerRow.cells[index].attribute("align")?.lowercased() {
            case "left": alignments[index] = .left
            case "center": alignments[index] = .center
            case "right": alignments[index] = .right
            default: break
            }
        }
        if !hasHeader {
            for index in 0..<min(columnCount, alignmentCells.count) {
                switch alignmentCells[index].attribute("align")?.lowercased() {
                case "left": alignments[index] = .left
                case "center": alignments[index] = .center
                case "right": alignments[index] = .right
                default: break
                }
            }
        }

        let bodyRows = rows.map { row in
            (0..<columnCount).map { index in
                guard index < row.cells.count else { return [MarkdownInline]() }
                return normalize(inline(from: row.cells[index].children))
            }
        }
        return MarkdownTable(header: header, rows: bodyRows, alignments: alignments)
    }

    private func nestedTableText(_ node: HTMLNode) -> String {
        var rows: [[String]] = []

        func collectRows(_ nodes: [HTMLNode]) {
            for child in nodes {
                guard case .element(let name, _, let children) = child else {
                    continue
                }
                if name == "tr" {
                    rows.append(
                        children.compactMap { cell in
                            guard cell.elementName == "th"
                                    || cell.elementName == "td" else {
                                return nil
                            }
                            return collapseWhitespace(
                                rawText(in: cell.children),
                                preserveNewlines: false
                            ).trimmingASCIIWhitespace()
                        }
                    )
                } else if name == "thead" || name == "tbody" || name == "tfoot" {
                    collectRows(children)
                }
            }
        }

        collectRows(node.children)
        return rows.map { $0.joined(separator: "\t") }
            .joined(separator: "&#xA;")
    }

    private mutating func makeDescriptionList(_ children: [HTMLNode]) -> [MarkdownBlock] {
        struct Group {
            var terms: [[MarkdownBlock]] = []
            var definitions: [(blocks: [MarkdownBlock], loose: Bool)] = []
        }

        func flattened(_ nodes: [HTMLNode]) -> [HTMLNode] {
            nodes.flatMap { node -> [HTMLNode] in
                if node.elementName == "div" {
                    return flattened(node.children)
                }
                return node.elementName == "dt" || node.elementName == "dd"
                    ? [node]
                    : []
            }
        }

        var groups: [Group] = []
        var current = Group()
        func finishCurrent() {
            if !current.terms.isEmpty || !current.definitions.isEmpty {
                groups.append(current)
            }
            current = Group()
        }

        for child in flattened(children) {
            let content = blocks(from: child.children)
            if child.elementName == "dt" {
                if !current.definitions.isEmpty {
                    finishCurrent()
                }
                if !content.isEmpty {
                    current.terms.append(content)
                }
            } else if !content.isEmpty {
                current.definitions.append(
                    (
                        blocks: content,
                        loose: child.children.contains {
                            guard let name = $0.elementName else { return false }
                            return Self.blockElements.contains(name)
                        }
                    )
                )
            }
        }
        finishCurrent()

        var items: [MarkdownListItem] = []
        for group in groups {
            var itemBlocks: [MarkdownBlock] = []
            if group.terms.count == 1 {
                itemBlocks.append(contentsOf: group.terms[0])
            } else if group.terms.count > 1 {
                itemBlocks.append(
                    .list(
                        ordered: false,
                        start: 1,
                        items: group.terms.map {
                            MarkdownListItem(
                                blocks: $0,
                                checked: nil,
                                loose: false
                            )
                        },
                        loose: false
                    )
                )
            }

            if group.definitions.count == 1 {
                itemBlocks.append(contentsOf: group.definitions[0].blocks)
            } else if group.definitions.count > 1 {
                let definitionsAreLoose = group.definitions.contains { $0.loose }
                itemBlocks.append(
                    .list(
                        ordered: false,
                        start: 1,
                        items: group.definitions.map {
                            MarkdownListItem(
                                blocks: $0.blocks,
                                checked: nil,
                                loose: definitionsAreLoose
                            )
                        },
                        loose: definitionsAreLoose
                    )
                )
            }
            if !itemBlocks.isEmpty {
                items.append(
                    MarkdownListItem(
                        blocks: itemBlocks,
                        checked: nil,
                        loose: true
                    )
                )
            }
        }
        guard !items.isEmpty else { return [] }
        return [.list(ordered: false, start: 1, items: items, loose: true)]
    }

    private mutating func inline(from nodes: [HTMLNode]) -> [MarkdownInline] {
        nodes.flatMap { inline(from: $0) }
    }

    private mutating func inline(from node: HTMLNode) -> [MarkdownInline] {
        switch node {
        case .text(let value):
            let collapsed = collapseWhitespace(value)
            return collapsed.isEmpty ? [] : [.text(collapsed)]

        case .comment(let value):
            return [.rawHTML("<!--\(value)-->")]

        case .element(let name, let attributes, let children):
            if Self.discardedElements.contains(name) {
                return []
            }

            switch name {
            case "#ignored":
                return [.rawHTML("")]
            case "br":
                return [.lineBreak]
            case "strong", "b":
                let content = normalize(inline(from: children))
                return content.isEmpty ? [] : [.strong(content)]
            case "em", "i", "mark", "u":
                let content = normalize(inline(from: children))
                return content.isEmpty ? [] : [.emphasis(content)]
            case "del", "s", "strike":
                let content = normalize(inline(from: children))
                return content.isEmpty ? [] : [.deletion(content)]
            case "code", "kbd", "samp", "tt", "var":
                let value = collapseWhitespace(
                    rawText(in: children),
                    preserveNewlines: false
                )
                    .trimmingASCIIWhitespace()
                    .replacingOccurrences(
                        of: #"&lt(?=[A-Za-z])"#,
                        with: "<",
                        options: .regularExpression
                    )
                return [.code(value)]
            case "q":
                let pair = options.quotes[quoteDepth % options.quotes.count]
                let opening = String(pair.first ?? "\"")
                let closing = String(pair.last ?? "\"")
                quoteDepth += 1
                let content = normalize(inline(from: children))
                quoteDepth -= 1
                return [.text(opening)] + content + [.text(closing)]
            case "a":
                let content = normalize(inline(from: children))
                return [
                    .link(
                        destination: attributes["href"] ?? "",
                        title: nonempty(attributes["title"]),
                        children: content
                    )
                ]
            case "img", "image":
                return implicitMediaPrefix() + [
                    .image(
                        source: attributes["src"] ?? "",
                        title: nonempty(attributes["title"]),
                        alt: attributes["alt"] ?? ""
                    )
                ]
            case "audio":
                return mediaInline(
                    children: children,
                    destination: mediaSource(attributes: attributes, children: children),
                    poster: nil,
                    title: nonempty(attributes["title"])
                )
            case "video":
                return mediaInline(
                    children: children,
                    destination: mediaSource(attributes: attributes, children: children),
                    poster: attributes["poster"],
                    title: nonempty(attributes["title"])
                )
            case "input":
                return inputInline(attributes)
            case "table":
                return [.rawHTML(nestedTableText(node))]
            case "select":
                return selectInline(node)
            case "textarea":
                let value = rawText(in: children).trimmingASCIIWhitespace()
                return value.isEmpty
                    ? [.rawHTML("")]
                    : [.rawHTML(""), .text(value), .rawHTML("")]
            case "iframe":
                guard let title = nonempty(attributes["title"]) else { return [] }
                return [
                    .link(
                        destination: attributes["src"] ?? "",
                        title: nil,
                        children: [.text(title)]
                    )
                ]
            case "canvas":
                return inline(from: children)
            case "button":
                let previousSuppression = suppressImplicitMediaSpacing
                suppressImplicitMediaSpacing = true
                let content = inline(from: children)
                suppressImplicitMediaSpacing = previousSuppression
                return content
            case "wbr":
                return [.text("\u{200B}")]
            default:
                return inline(from: children)
            }
        }
    }

    private mutating func inputInline(
        _ attributes: [String: String]
    ) -> [MarkdownInline] {
        let type = attributes["type"]?.lowercased() ?? "text"

        if type == "checkbox" || type == "radio" {
            guard !suppressTaskCheckboxes else { return [] }
            return [
                .text(
                    attributes["checked"] == nil
                        ? options.unchecked
                        : options.checked
                )
            ]
        }

        if attributes["disabled"] != nil || type == "hidden" || type == "file" {
            return [.rawHTML("")]
        }

        if type == "image" {
            let source = attributes["src"] ?? ""
            let alt = attributes["alt"] ?? attributes["value"] ?? ""
            guard !alt.isEmpty else { return [.rawHTML("")] }
            return implicitMediaPrefix() + [
                .image(
                    source: source,
                    title: nonempty(attributes["title"]),
                    alt: alt
                )
            ]
        }

        if let explicitValue = attributes["value"], !explicitValue.isEmpty {
            if type == "password" {
                return [.text(String(repeating: "•", count: explicitValue.count))]
            }
            return controlValueInline(explicitValue, type: type)
        }

        if type == "password" {
            return [.rawHTML("")]
        }

        if let list = attributes["list"],
           let choices = datalists[list] {
            let values = selectedChoices(
                from: choices,
                multiple: attributes["multiple"] != nil
            ).map(choiceInline)
            if !values.isEmpty {
                return joined(values, separator: ", ")
            }
        }

        if let placeholder = attributes["placeholder"], !placeholder.isEmpty {
            if type == "password" {
                return [.rawHTML("")]
            }
            return controlValueInline(placeholder, type: type)
        }
        return [.rawHTML("")]
    }

    private mutating func selectInline(_ node: HTMLNode) -> [MarkdownInline] {
        let choices = formChoices(in: node.children)
        let selected = selectedChoices(
            from: choices,
            multiple: node.attribute("multiple") != nil
        )
        return joined(selected.map(choiceInline), separator: ", ")
    }

    private func selectedChoices(
        from choices: [FormChoice],
        multiple: Bool
    ) -> [FormChoice] {
        let enabled = choices.filter { !$0.disabled }
        if multiple {
            return enabled.filter(\.selected)
        }
        if let selected = enabled.first(where: \.selected) {
            return [selected]
        }
        return enabled.first.map { [$0] } ?? []
    }

    private func choiceInline(_ choice: FormChoice) -> [MarkdownInline] {
        let label = choice.label.isEmpty ? choice.value : choice.label
        let content = controlValueInline(choice.value, type: inferredType(choice.value))

        if choice.value.isEmpty {
            return label.isEmpty ? [] : [.text(label)]
        }
        if label == choice.value {
            return content
        }
        if choice.value.hasPrefix("http://") || choice.value.hasPrefix("https://") {
            return [
                .link(
                    destination: choice.value,
                    title: nil,
                    children: [.text(label)]
                )
            ]
        }
        if inferredType(choice.value) == "email" {
            return [
                .link(
                    destination: "mailto:\(choice.value)",
                    title: nil,
                    children: [.text(label)]
                )
            ]
        }
        return [.text("\(label) (\(choice.value))")]
    }

    private func controlValueInline(_ value: String, type: String) -> [MarkdownInline] {
        if type == "url" {
            return [.link(destination: value, title: nil, children: [.text(value)])]
        }
        if type == "email" {
            return [
                .link(
                    destination: "mailto:\(value)",
                    title: nil,
                    children: [.text(value)]
                )
            ]
        }
        return [.text(value)]
    }

    private func inferredType(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return "url"
        }
        if value.range(
            of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
            options: .regularExpression
        ) != nil {
            return "email"
        }
        return "text"
    }

    private func joined(
        _ groups: [[MarkdownInline]],
        separator: String
    ) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for (index, group) in groups.enumerated() {
            if index > 0 {
                result.append(.text(separator))
            }
            result.append(contentsOf: group)
        }
        return result
    }

    private mutating func collectDatalists(in nodes: [HTMLNode]) {
        for node in nodes {
            if node.elementName == "datalist", let id = node.attribute("id") {
                datalists[id] = formChoices(in: node.children)
            }
            collectDatalists(in: node.children)
        }
    }

    private func formChoices(
        in nodes: [HTMLNode],
        inheritedDisabled: Bool = false
    ) -> [FormChoice] {
        var result: [FormChoice] = []
        for node in nodes {
            guard case .element(let name, let attributes, let children) = node else {
                continue
            }
            let disabled = inheritedDisabled || attributes["disabled"] != nil
            if name == "option" {
                let text = collapseWhitespace(rawText(in: children)).trimmingASCIIWhitespace()
                let value = attributes["value"] ?? text
                let label = attributes["label"] ?? text
                result.append(
                    FormChoice(
                        value: value,
                        label: label,
                        selected: attributes["selected"] != nil,
                        disabled: disabled
                    )
                )
            } else {
                result.append(
                    contentsOf: formChoices(
                        in: children,
                        inheritedDisabled: disabled
                    )
                )
            }
        }
        return result
    }

    private mutating func mediaInline(
        children: [HTMLNode],
        destination: String,
        poster: String?,
        title: String?
    ) -> [MarkdownInline] {
        let fallbackNodes = children.filter {
            $0.elementName != "source" && $0.elementName != "track"
        }
        let fallback = normalize(inline(from: fallbackNodes))

        if containsLink(to: destination, in: fallbackNodes) {
            return fallback
        }

        let content: [MarkdownInline]
        if let poster {
            content = [
                .image(
                    source: poster,
                    title: nil,
                    alt: plainText(fallback)
                )
            ]
        } else {
            content = fallback
        }
        return implicitMediaPrefix()
            + [.link(destination: destination, title: title, children: content)]
    }

    private func implicitMediaPrefix() -> [MarkdownInline] {
        suppressImplicitMediaSpacing ? [] : [.text(" ")]
    }

    private func containsLink(to destination: String, in nodes: [HTMLNode]) -> Bool {
        for node in nodes {
            if node.elementName == "a", node.attribute("href") == destination {
                return true
            }
            if containsLink(to: destination, in: node.children) {
                return true
            }
        }
        return false
    }

    private func mediaSource(
        attributes: [String: String],
        children: [HTMLNode]
    ) -> String {
        if let source = attributes["src"] {
            return source
        }
        return firstElement(named: "source", in: children)?.attribute("src") ?? ""
    }

    private func containsBlockElement(_ node: HTMLNode) -> Bool {
        for child in node.children {
            if let name = child.elementName, Self.blockElements.contains(name) {
                return true
            }
            if containsBlockElement(child) {
                return true
            }
        }
        return false
    }

    private func wrapInlineContent(
        in blocks: [MarkdownBlock],
        transform: ([MarkdownInline]) -> [MarkdownInline]
    ) -> [MarkdownBlock] {
        blocks.map { block in
            switch block {
            case .paragraph(let children):
                return .paragraph(transform(children))
            case .heading(let level, let children, let id):
                return .heading(
                    level: level,
                    children: transform(children),
                    id: id
                )
            case .blockquote(let children):
                return .blockquote(
                    wrapInlineContent(in: children, transform: transform)
                )
            case .list(let ordered, let start, let items, let loose):
                return .list(
                    ordered: ordered,
                    start: start,
                    items: items.map {
                        MarkdownListItem(
                            blocks: wrapInlineContent(
                                in: $0.blocks,
                                transform: transform
                            ),
                            checked: $0.checked,
                            loose: $0.loose
                        )
                    },
                    loose: loose
                )
            case .table(var table):
                table.header = table.header.map(transform)
                table.rows = table.rows.map { $0.map(transform) }
                return .table(table)
            case .code, .thematicBreak:
                return block
            }
        }
    }

    private func containsElement(named name: String, in node: HTMLNode) -> Bool {
        if node.elementName == name {
            return true
        }
        return node.children.contains { containsElement(named: name, in: $0) }
    }

    private func firstElement(named name: String, in nodes: [HTMLNode]) -> HTMLNode? {
        for node in nodes {
            if node.elementName == name {
                return node
            }
            if let result = firstElement(named: name, in: node.children) {
                return result
            }
        }
        return nil
    }

    private func rawText(in nodes: [HTMLNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value):
                return value
            case .comment(let value):
                return "<!--\(value)-->"
            case .element(let name, _, let children):
                return name == "br" ? "\n" : rawText(in: children)
            }
        }.joined()
    }

    private func preformattedText(in nodes: [HTMLNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value):
                return value
            case .comment:
                return ""
            case .element(let name, _, let children):
                if name == "br" {
                    return "\n"
                }
                let value = preformattedText(in: children)
                if Self.blockElements.contains(name), !value.isEmpty {
                    return "\n\(value)\n"
                }
                return value
            }
        }.joined()
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

    private func collapseWhitespace(_ value: String) -> String {
        collapseWhitespace(value, preserveNewlines: options.newlines)
    }

    private func collapseWhitespace(
        _ value: String,
        preserveNewlines: Bool
    ) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result = ""
        var inWhitespace = false
        var afterPreservedNewline = false
        for scalar in normalized.unicodeScalars {
            if preserveNewlines, scalar == "\n" {
                result = result.trimmingTrailingASCIIWhitespace()
                result.append("\n")
                inWhitespace = false
                afterPreservedNewline = true
                continue
            }

            let isHTMLWhitespace = scalar == " " || scalar == "\t"
                || scalar == "\u{000C}" || scalar == "\n"
            if isHTMLWhitespace {
                if !inWhitespace && !afterPreservedNewline {
                    result.append(" ")
                    inWhitespace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                inWhitespace = false
                afterPreservedNewline = false
            }
        }
        return result
    }

    private func normalize(_ input: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for item in input {
            if case .lineBreak = item, result.isEmpty {
                continue
            }
            if case .lineBreak = item, case .lineBreak? = result.last {
                continue
            }
            if case .lineBreak = item,
               case .text(let value)? = result.last {
                let trimmed = value.trimmingTrailingASCIIWhitespace()
                if trimmed.isEmpty {
                    result.removeLast()
                } else {
                    result[result.count - 1] = .text(trimmed)
                }
            }
            if case .text(let value) = item,
               case .lineBreak? = result.last {
                let trimmed = value.trimmingLeadingASCIIWhitespace()
                if !trimmed.isEmpty {
                    result.append(.text(trimmed))
                }
                continue
            }
            if case .text(let value) = item,
               case .text(let previous)? = result.last {
                result[result.count - 1] = .text(collapseWhitespace(previous + value))
            } else {
                result.append(item)
            }
        }

        while let first = result.first {
            if case .rawHTML(let value) = first, value.isEmpty {
                result.removeFirst()
                continue
            }
            if case .text(let value) = first {
                let trimmed = value.trimmingLeadingASCIIWhitespace()
                if trimmed.isEmpty {
                    result.removeFirst()
                    continue
                }
                result[0] = .text(trimmed)
            }
            break
        }
        while let last = result.last {
            if case .rawHTML(let value) = last, value.isEmpty {
                result.removeLast()
                continue
            }
            if case .text(let value) = last {
                let trimmed = value.trimmingTrailingASCIIWhitespace()
                if trimmed.isEmpty {
                    result.removeLast()
                    continue
                }
                result[result.count - 1] = .text(trimmed)
            }
            break
        }
        while case .lineBreak? = result.last {
            result.removeLast()
        }
        return result
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    func trimmingLeadingASCIIWhitespace() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }))
    }

    func trimmingTrailingASCIIWhitespace() -> String {
        String(reversed().drop(while: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }).reversed())
    }

    func trimmingASCIIWhitespace() -> String {
        trimmingLeadingASCIIWhitespace().trimmingTrailingASCIIWhitespace()
    }
}

private extension MarkdownBlock {
    var isEmptyParagraph: Bool {
        guard case .paragraph(let children) = self else { return false }
        return children.isEmpty || children.allSatisfy {
            if case .rawHTML(let value) = $0 {
                return value.isEmpty
            }
            return false
        }
    }
}
