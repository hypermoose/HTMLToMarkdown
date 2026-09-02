import Foundation
import Testing
@testable import HTMLToMarkdown

private let converter = try! HTMLToMarkdown()

@Test func compatibilityFixtures() throws {
    let fixtures: [(String, [String: Any], String)] = [
        (
            #"<p>Hello <b>bold</b> <i>italic</i> <del>gone</del><br>next &amp; &copy; &#x1F600;</p>"#,
            [:],
            "Hello **bold** *italic* ~~gone~~\\\nnext & © 😀\n"
        ),
        (
            #"<ol start="3"><li>three</li><li value="8">eight</li><li><p>nine para</p><p>second</p></li></ol>"#,
            [:],
            "3. three\n\n4. eight\n\n5. nine para\n\n   second\n"
        ),
        (
            #"<ul><li><input type="checkbox" checked disabled> done</li><li><input type="checkbox"> todo</li></ul>"#,
            [:],
            "* [x] done\n* [ ] todo\n"
        ),
        (
            "<ul><li>one<ul><li>two<ul><li>three</li></ul></li></ul></li></ul>",
            [:],
            "* one\n  * two\n    * three\n"
        ),
        (
            "<blockquote><p>one</p><blockquote><p>two<br>next</p></blockquote></blockquote>",
            [:],
            "> one\n>\n> > two\\\n> > next\n"
        ),
        (
            #"<a href="https://example.com">https://example.com</a> <a href="mailto:a@b.com">a@b.com</a> <a href="/x" title="say &quot;hi&quot;">link</a>"#,
            [:],
            "<https://example.com> <a@b.com> [link](/x \"say \\\"hi\\\"\")\n"
        ),
        (
            #"<table><tr><td>a</td><td>b</td></tr><tr><td>x|y</td><td><strong>z</strong><br>q</td></tr></table>"#,
            [:],
            "|      |         |\n| ---- | ------- |\n| a    | b       |\n| x\\|y | **z** q |\n"
        ),
        (
            #"<table><thead><tr><th align="center">A</th><th align="right">Long</th></tr></thead><tbody><tr><td>x</td><td></td></tr></tbody></table>"#,
            [:],
            "|  A  | Long |\n| :-: | ---: |\n|  x  |      |\n"
        ),
        (
            "before<!--rehype:ignore:start--><b>hidden</b><!--rehype:ignore:end-->after",
            [:],
            "beforeafter\n"
        ),
        (
            #"<iframe src="x">fallback</iframe><audio src="a.mp3" controls></audio><video src="v.mp4" poster="p.jpg"><track></video>"#,
            [:],
            "[](a.mp3) [![](p.jpg)](v.mp4)\n"
        ),
        (
            "<h1>Hello World!</h1><h2>Hello World!</h2><h2>Café &amp; déjà_vu</h2>",
            ["enableAutolinkHeadings": true],
            "# [](#hello-world)Hello World!\n\n## [](#hello-world-1)Hello World!\n\n## [](#café--déjà_vu)Café & déjà\\_vu\n"
        ),
        (
            "<!doctype html><html><head><title>T</title><style>x{}</style><script>alert(1)</script></head><body><main><section><h1>Hi</h1><p>P</p></section></main></body></html>",
            ["fragment": false],
            "# Hi\n\nP\n"
        ),
        (
            #"<a href="">x</a><a>x</a><img src="" alt="a"><img alt="b">"#,
            [:],
            "[x]()[x]() ![a]() ![b]()\n"
        ),
        (
            "<p><u>under</u> <mark>mark</mark> H<sub>2</sub>O x<sup>2</sup> <kbd>Cmd</kbd> <small>small</small></p>",
            [:],
            "*under* *mark* H2O x2 `Cmd` small\n"
        ),
        (
            #"<figure><img src="x"><figcaption>Caption <b>bold</b></figcaption></figure>"#,
            [:],
            "![](x)\n\nCaption **bold**\n"
        ),
        (
            #"<table><thead><tr><th colspan="2">Head</th></tr></thead><tbody><tr><td>A</td><td>B</td></tr></tbody></table>"#,
            [:],
            "| Head |   |\n| ---- | - |\n| A    | B |\n"
        ),
        (
            #"<table><tr><th>A</th><th>B</th></tr><tr><td rowspan="2">X</td><td>Y</td></tr><tr><td>Z</td></tr></table>"#,
            [:],
            "| A | B |\n| - | - |\n| X | Y |\n|   | Z |\n"
        ),
        (
            "<h1></h1><p></p><hr><p>&nbsp;</p>",
            [:],
            "#\n\n***\n\n \n"
        ),
        (
            "<ul><li></li><li>a</li></ul>",
            [:],
            "*\n* a\n"
        ),
        (
            "# heading",
            [:],
            "\\# heading\n"
        ),
        (
            "1. item",
            [:],
            "1\\. item\n"
        ),
        (
            "<p>https://example.com test www.example.com a@b.com</p>",
            [:],
            "https\\://example.com test www\\.example.com a\\@b.com\n"
        ),
        (
            "<pre><code>\nline\n\n</code></pre>",
            [:],
            "```\n\nline\n```\n"
        ),
        (
            "<h1>x</h1>",
            ["enableAutolinkHeadings": 1],
            "# [](#x)x\n"
        )
    ]

    for (html, options, expected) in fixtures {
        let actual = try converter.conversion(html, options: options)
        #expect(
            actual == expected,
            "Input: \(html)\nExpected: \(expected.debugDescription)\nActual: \(actual.debugDescription)"
        )
    }
}

@Test func rejectsUnsupportedRuleLikeRemarkStringify() throws {
    do {
        _ = try converter.conversion("<hr>", options: ["rule": "x"])
        Issue.record("Expected an unsupported rule to throw")
    } catch let error as HTMLToMarkdownError {
        #expect(
            error.description
                == "Conversion failed: Cannot serialize rules with `x` for `options.rule`, expected `*`, `-`, or `_`"
        )
    }
}

@Test func canConvertConcurrentlyOffMainThread() async throws {
    let shared = try HTMLToMarkdown()
    let results = try await withThrowingTaskGroup(of: String.self) { group in
        for value in 0..<100 {
            group.addTask {
                try shared.conversion("<p>Item <strong>\(value)</strong></p>")
            }
        }

        var values: [String] = []
        for try await value in group {
            values.append(value)
        }
        return values
    }

    #expect(results.count == 100)
    #expect(Set(results).count == 100)
    #expect(results.allSatisfy { $0.hasPrefix("Item **") })
}
