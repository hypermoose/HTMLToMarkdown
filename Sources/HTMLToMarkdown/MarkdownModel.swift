indirect enum MarkdownInline: Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case deletion([MarkdownInline])
    case code(String)
    case link(destination: String, title: String?, children: [MarkdownInline])
    case image(source: String, title: String?, alt: String)
    case rawHTML(String)
    case lineBreak
}

struct MarkdownListItem: Sendable {
    var blocks: [MarkdownBlock]
    var checked: Bool?
    var loose: Bool
}

enum TableAlignment: Sendable {
    case left
    case center
    case right
}

struct MarkdownTable: Sendable {
    var header: [[MarkdownInline]]
    var rows: [[[MarkdownInline]]]
    var alignments: [TableAlignment?]
}

indirect enum MarkdownBlock: Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, children: [MarkdownInline], id: String?)
    case blockquote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem], loose: Bool)
    case code(language: String?, value: String)
    case thematicBreak
    case table(MarkdownTable)
}
