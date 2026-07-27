# HTMLToMarkdown — native Swift implementation

This directory contains the native Swift replacement for the repository's
JavaScriptCore-backed HTML-to-Markdown converter.

It intentionally exists **side by side** with the original package:

- The repository root is the legacy implementation. It loads
  `html-to-markdown.bundle.min.js` through JavaScriptCore and must run on the
  main thread.
- `native/` is an independent Swift package. It does not import
  JavaScriptCore, does not execute JavaScript, and can run on any thread.

Do not remove, move, or silently rewrite the root implementation while working
on this package. The ability to build and compare both implementations is a
project requirement.

## Current status

Status at the end of the native compatibility work on 2026-07-26:

- 127/127 exact matches against the downloaded upstream
  `syntax-tree/hast-util-to-mdast` fixture corpus.
- 24/24 permanent native tests pass.
- 24/24 tests pass under Thread Sanitizer.
- The concurrency test performs 100 conversions through one shared converter
  from concurrent tasks.
- The original root JSCore package remains unchanged.

The corpus score progressed from 68/127 in the initial native implementation,
to 119/127 after the first feature-completeness pass, and finally to 127/127.

The native output matches the legacy bundle on 118/127 corpus fixtures. The
nine deliberate differences are:

`base`, `input-checkbox-radio`, `listing`, `newlines-on`, `plaintext`, `quotes`,
`quotes-alt`, `ruby-rt-rp-rbc-rtc-rb`, and `text-wrap`.

These are not known native regressions. The final native output matches the
current upstream expected Markdown for all nine. They differ because the
bundled JS represents an older or narrower behavior set:

- The legacy JavaScriptCore environment lacks the global `URL` needed by its
  `<base>` handling.
- The root wrapper's bundled entry point only exposes
  `enableAutolinkHeadings`, `fragment`, and `rule`; current upstream behaviors
  also include custom checkbox markers, quote pairs, and newline preservation.
- Current upstream whitespace behavior differs for legacy ruby,
  `listing`/`plaintext`, and newline-sensitive serialization.

When deciding whether to copy the old output or the upstream expected output,
prefer current upstream compatibility unless the user explicitly asks for
byte-for-byte legacy behavior.

## Package and API

The package uses Swift tools 6.1 and currently supports:

- iOS 13+
- macOS 10.15+
- tvOS 13+
- watchOS 6+

Its only package dependency is SwiftSoup 2.13.7. SwiftSoup is the native HTML5
parser; it is not a JavaScript runtime.

The public API is source-compatible with the root package:

```swift
import HTMLToMarkdown

let converter = try HTMLToMarkdown()
let markdown = try converter.conversion("<p>Hello <strong>world</strong>.</p>")
// "Hello **world**.\n"
```

The options dictionary is JSON-validated to preserve the old wrapper's
behavior:

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

Supported options and defaults:

| Option | Default | Meaning |
| --- | --- | --- |
| `checked` | `"[x]"` | Text for checked checkbox/radio controls outside task lists |
| `enableAutolinkHeadings` | `false` | Prefix headings with links to unique generated IDs |
| `fragment` | `true` | Parse the input as an HTML body fragment |
| `newlines` | `false` | Preserve source line feeds where Markdown permits them |
| `quotes` | `["\"\""]` | Cyclic opening/closing pairs used for nested `<q>` elements |
| `rule` | `"*"` | Thematic-break character: `"*"`, `"-"`, or `"_"` |
| `unchecked` | `"[ ]"` | Text for unchecked checkbox/radio controls outside task lists |

Task-list checkboxes remain `[x]` and `[ ]`; the custom marker options apply to
standalone form controls, matching upstream behavior.

`HTMLToMarkdown` is stateless and `Sendable`, so one instance can be shared:

```swift
let converter = try HTMLToMarkdown()

let markdown = try await Task.detached {
    try converter.conversion(html)
}.value
```

## Architecture

The conversion pipeline is:

```text
HTML string
  -> SwiftSoup HTML5 parse
  -> small Sendable HTMLNode tree
  -> MarkdownBuilder block/inline model
  -> MarkdownSerializer
  -> Markdown string
```

Source ownership:

- `Sources/HTMLToMarkdown/HTMLToMarkdown.swift`
  - Public API and compatibility errors.
  - JSON option validation and `ConversionOptions`.
- `Sources/HTMLToMarkdown/HTMLDocument.swift`
  - SwiftSoup integration.
  - Converts SwiftSoup nodes into the package's small HTML tree.
  - Handles comments, ignore boundaries, captured attributes, and `<base>` URL
    resolution.
- `Sources/HTMLToMarkdown/MarkdownModel.swift`
  - Internal block and inline Markdown types.
  - Types are value-based and `Sendable`.
- `Sources/HTMLToMarkdown/NativeHTMLToMarkdown.swift`
  - HTML-to-Markdown semantic conversion.
  - Contains element handlers, form/media/table behavior, implicit paragraph
    logic, and whitespace normalization.
- `Sources/HTMLToMarkdown/MarkdownSerializer.swift`
  - Escaping and final Markdown formatting.
  - Handles lists, tables, headings, code fences, autolinks, and contextual
    newline behavior.

All mutable conversion state is created inside a single call. In particular,
datalists, nested quote depth, task-checkbox suppression, implicit media
spacing, slug counts, and paragraph-boundary state must never become shared
static or instance state on the public converter.

## Behavior already covered

The native implementation includes more than basic tag replacement. Existing
coverage includes:

- Headings, paragraphs, emphasis, strong text, deletion, links, images,
  autolinks, code, fenced code blocks, blockquotes, thematic breaks, and nested
  ordered/unordered/task lists.
- GFM tables with alignment, column/row spans, comments, empty tables, correct
  UTF-16 width calculation, and nested-table tab/row encoding.
- Full-document and fragment parsing, ignored nodes, rehype ignore comments,
  ordinary HTML comments, and `<base>` URL resolution.
- Form inputs, password masking, checkbox/radio markers, datalists,
  placeholders, selects, options, optgroups, multiple selection, disabled
  controls, and image inputs.
- Audio/video sources and fallbacks, poster images, iframes, canvas/object
  fallbacks, and the legacy `<image>` alias.
- Description lists, ruby-related elements, quotes, semantic inline elements,
  preformatted elements, and discarded non-content elements.
- Straddling inline elements that contain block children, including the
  upstream whitespace ownership rules for implicit paragraphs.
- Source newline preservation with context-specific handling:
  - Paragraph text can retain line feeds.
  - Level-one/two multiline headings use Setext form.
  - Higher headings encode source line feeds as `&#xA;`.
  - `<br>` is flattened where multiline Markdown is invalid.
  - Table-cell source line feeds use `&#xA;`.

Whitespace is the most fragile part of this converter. Do not globally trim or
collapse text to fix one fixture. Whitespace may belong inside a link label,
between implicit paragraphs, or on both sides of a block-spanning fallback.
Add a focused regression before changing normalization.

## Permanent tests

Tests live in `Tests/HTMLToMarkdownTests/`:

- `HTMLToMarkdownTests.swift` contains the original public examples and basic
  conversion tests.
- `CompatibilityTests.swift` covers legacy API/output behavior, option errors,
  escaping, tables, and the 100-task concurrency test.
- `MissingFeatureTests.swift` covers features discovered while assessing the
  larger upstream corpus.

Run the permanent suite from `native/`:

```sh
swift test --scratch-path /tmp/html-to-markdown-native-build
```

Run Thread Sanitizer:

```sh
swift test \
  --scratch-path /tmp/html-to-markdown-native-tsan-build \
  --sanitize=thread
```

Run an optimized build when changing serializer behavior or doing performance
work:

```sh
swift test \
  --scratch-path /tmp/html-to-markdown-native-release-build \
  -c release
```

Use a scratch path under `/tmp` to avoid adding build products to this
directory.

## Upstream corpus and scoring

The expanded compatibility corpus came from:

```text
https://github.com/syntax-tree/hast-util-to-mdast
test/fixtures/
```

It was downloaded into:

```text
/tmp/html-to-markdown-corpus-hast-mdast/test/fixtures
```

The `/tmp` checkout and generated result JSON are intentionally not part of the
repository and may be absent in a later session. Re-download the repository if
needed:

```sh
git clone --depth 1 \
  https://github.com/syntax-tree/hast-util-to-mdast.git \
  /tmp/html-to-markdown-corpus-hast-mdast
```

Each relevant fixture directory contains:

- `index.html`: input HTML
- `index.json`: conversion options
- `index.md`: expected Markdown

The final score was calculated by:

1. Enumerating all 127 fixture directories.
2. Loading `index.json` as `[String: Any]`.
3. Calling the native public `conversion(_:options:)` API.
4. Comparing the complete returned string to `index.md`, including final
   newlines and whitespace.

The temporary Swift corpus-runner test used to produce the score was removed
after validation. Do not leave ad hoc corpus runners in the permanent suite.
If the upstream corpus changes, record its commit SHA and report the new
fixture count so a future score remains meaningful.

## Comparing with the root JSCore implementation

The two packages export the same module and type names, so do not link both
products into one test process. Build separate executables or test processes,
feed them the same fixture set, and compare serialized results afterward.

For performance comparisons:

- Use release builds.
- Warm each implementation before recording measurements.
- Run each implementation in a separate process.
- Use the same input order and iteration count.
- Report wall time, CPU time, peak resident memory, fixture count, hardware,
  and OS/Swift version.
- Keep main-thread dispatch in the legacy measurement because it is part of
  that implementation's actual constraint.

An earlier ad hoc side-by-side CPU/memory assessment motivated this work, but
its raw benchmark artifacts and machine-specific figures were not committed.
Do not quote a numeric performance advantage without rerunning a reproducible
benchmark.

## Guardrails for future work

1. Keep the root JSCore implementation and `native/` side by side.
2. Make native changes only under `native/` unless the user explicitly expands
   the scope.
3. Preserve the public API and JSON validation behavior.
4. Keep the public converter stateless and `Sendable`.
5. Add a focused permanent test for every compatibility fix.
6. Run the full suite and Thread Sanitizer after changing state or traversal.
7. Rescore all 127 fixtures after changing parsing, whitespace, tables, forms,
   media, or serialization.
8. Compare exact strings; visually similar Markdown is not sufficient.
9. Treat the entire `native/` directory as user work even if `git status`
   reports it as untracked. Never discard it as build output.
10. Do not commit `/tmp` corpus checkouts, generated result JSON, or SwiftPM
    scratch builds.

## Installation

Add `native/` as a local Swift package in Xcode, or reference it from another
local package:

```swift
dependencies: [
    .package(path: "../HTMLToMarkdown/native")
]
```

## License

Licensed under the MIT License. See `native/LICENSE`.
