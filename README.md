# HTMLToMarkdown

A fully native Swift library for converting HTML to Markdown.

This implementation does not use JavaScriptCore, execute JavaScript, or ship a
JavaScript bundle. It parses HTML with
[SwiftSoup](https://github.com/scinfu/SwiftSoup) and converts the resulting
document to Markdown entirely in Swift.

This project is a native rewrite of the
[original JavaScriptCore-backed HTMLToMarkdown library](https://github.com/jaywcjlove/HTMLToMarkdown).
It preserves the original public API while adding safe concurrent conversion
and broader compatibility with current HTML-to-Markdown behavior.

## Features

- Fully native Swift implementation
- Source-compatible with the original `HTMLToMarkdown` API
- Stateless, `Sendable` converter that can run on any thread
- HTML5 parsing through SwiftSoup
- Headings, links, images, emphasis, code, blockquotes, and thematic breaks
- Ordered, unordered, nested, and task lists
- GitHub Flavored Markdown tables, including alignment and spans
- Form controls, media elements, description lists, and semantic HTML
- Full-document and HTML-fragment parsing
- Configurable heading links, rule characters, quote pairs, and newlines

## Requirements

- Swift 6.1+
- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+

## Installation

### Swift Package Manager

In Xcode, select **File → Add Package Dependencies…** and enter:

```text
https://github.com/hypermoose/HTMLToMarkdown.git
```

Or add the package to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/hypermoose/HTMLToMarkdown.git",
        branch: "main"
    )
]
```

Then add `HTMLToMarkdown` to your target's dependencies.

## Usage

```swift
import HTMLToMarkdown

let converter = try HTMLToMarkdown()
let markdown = try converter.conversion("""
<h2>Hello</h2>
<p>This is <strong>native Swift</strong>.</p>
""")

// ## Hello
//
// This is **native Swift**.
```

The converter is stateless and `Sendable`, so an instance can safely be
shared between tasks:

```swift
let converter = try HTMLToMarkdown()

let markdown = try await Task.detached {
    try converter.conversion("<p>Converted off the main thread.</p>")
}.value
```

## Options

Pass conversion options with the source-compatible
`conversion(_:options:)` API:

```swift
let markdown = try converter.conversion(
    html,
    options: [
        "checked": "✓",
        "enableAutolinkHeadings": true,
        "fragment": true,
        "newlines": true,
        "quotes": ["“”", "‘’"],
        "rule": "-",
        "unchecked": "✗"
    ]
)
```

| Option | Default | Description |
| --- | --- | --- |
| `checked` | `"[x]"` | Marker for checked controls outside task lists |
| `enableAutolinkHeadings` | `false` | Adds unique anchor links to headings |
| `fragment` | `true` | Parses input as an HTML body fragment |
| `newlines` | `false` | Preserves source newlines where Markdown permits |
| `quotes` | `["\"\""]` | Opening and closing pairs for nested `<q>` elements |
| `rule` | `"*"` | Thematic-break character: `*`, `-`, or `_` |
| `unchecked` | `"[ ]"` | Marker for unchecked controls outside task lists |

## Compatibility

The original public examples remain exact-output tests. The native
implementation also includes expanded tests for malformed and semantic HTML,
tables, forms, media, options, and concurrent use. It has been validated
against all 127 fixtures from
[`syntax-tree/hast-util-to-mdast`](https://github.com/syntax-tree/hast-util-to-mdast).

Where the bundled JavaScript implementation and current upstream behavior
differ, this version follows current upstream behavior. Existing callers can
continue using:

```swift
let converter = try HTMLToMarkdown()
let markdown = try converter.conversion(html)
```

## Development

Run the test suite:

```sh
swift test
```

Run the suite with Thread Sanitizer:

```sh
swift test --sanitize=thread
```

## License

Licensed under the MIT License. See [LICENSE](LICENSE).
