import Testing
@testable import HTMLToMarkdown

private let featureConverter = try! HTMLToMarkdown()

@Test func preservesDocumentAndAnnotationSemantics() throws {
    let fixtures: [(html: String, expected: String)] = [
        (
            "<!doctype html><html><head><title>Hidden</title></head>"
                + "<body><p>Visible</p></body></html>",
            "Visible\n"
        ),
        (
            "<!-- alpha --><p>One <em data-mdast=\"ignore\">hidden</em> two.</p>"
                + "<!-- beta -->",
            "<!-- alpha -->\n\nOne  two.\n\n<!-- beta -->\n"
        ),
        (
            "<html><head><base href=\"https://example.com/docs/\"></head>"
                + "<body><a href=\"guide.html\">Guide</a></body></html>",
            "[Guide](https://example.com/docs/guide.html)\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(fixture.html)
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func convertsFormControlsAndSelections() throws {
    let fixtures: [(html: String, expected: String)] = [
        (
            "<p>Text: <input value=\"alpha\"> Password: "
                + "<input type=\"password\" value=\"secret\"> "
                + "<input type=\"checkbox\" checked> yes <input type=\"radio\"> no</p>",
            "Text: alpha Password: •••••• \\[x] yes \\[ ] no\n"
        ),
        (
            "<p>One: <select><option>first</option>"
                + "<option selected value=\"second\">Second</option></select> "
                + "Many: <select multiple><option selected>A</option><option>B</option>"
                + "<option selected>C</option></select></p>",
            "One: Second (second) Many: A, C\n"
        ),
        (
            "<p>Browser: <input list=\"browsers\"></p>"
                + "<datalist id=\"browsers\"><option value=\"Chrome\">"
                + "<option value=\"Safari\" selected></datalist>",
            "Browser: Safari\n"
        ),
        (
            "<p>Name: <input placeholder=\"Jane\"> Email: "
                + "<input type=\"email\" placeholder=\"jane@example.com\"></p>",
            "Name: Jane Email: <jane@example.com>\n"
        ),
        (
            "<p>Value: <input value=\"considerations\"> stems to: "
                + "<output>consider</output></p>",
            "Value: considerations stems to: consider\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(fixture.html)
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func convertsFallbackAndSemanticElements() throws {
    let fixtures: [(html: String, expected: String)] = [
        (
            "<canvas><img src=\"fallback.png\" alt=\"Fallback\"></canvas>"
                + "<figure><svg>hidden</svg><figcaption>Caption</figcaption></figure>"
                + "<figure><math>x</math><figcaption>Equation</figcaption></figure>",
            "![Fallback](fallback.png)\n\nCaption\n\nEquation\n"
        ),
        (
            "<iframe src=\"x.html\" title=\"X\">fallback</iframe>"
                + "<iframe src=\"y.html\"></iframe>",
            "[X](x.html)\n"
        ),
        (
            "<p><q>Hello <em>world</em></q> <samp>sample</samp> "
                + "<tt>teletype</tt> <var>x</var></p>",
            "\"Hello *world*\" `sample` `teletype` `x`\n"
        ),
        (
            "<image src=\"x.png\" alt=\"X\" title=\"T\">",
            "![X](x.png \"T\")\n"
        ),
        (
            "<dialog open><p>Hidden</p></dialog>"
                + "<menu type=\"context\"><menuitem>A</menuitem></menu><p>Shown</p>",
            "Shown\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(fixture.html)
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func convertsMediaAndPreformattedFallbacks() throws {
    let fixtures: [(html: String, expected: String)] = [
        (
            "<p><audio src=\"a.mp3\" title=\"Song\">Audio</audio> "
                + "<video src=\"v.mp4\" poster=\"p.png\" title=\"Film\">"
                + "Video <em>fallback</em></video></p>",
            "[Audio](a.mp3 \"Song\") [![Video fallback](p.png)](v.mp4 \"Film\")\n"
        ),
        (
            "<pre>alpha <code>beta()</code> gamma<br>delta</pre>"
                + "<listing>one <b>two</b></listing><xmp><b>raw</b></xmp>",
            "```\nalpha beta() gamma\ndelta\n```\n\n"
                + "```\none two\n```\n\n"
                + "```\n<b>raw</b>\n```\n"
        ),
        (
            "<p><br>alpha<br></p><h1><br>heading<br></h1><p>omega<br><br></p>",
            "alpha\n\n# heading\n\nomega\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(fixture.html)
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func preservesStructuralFallbacksAndTableAnnotations() throws {
    let fixtures: [(html: String, expected: String)] = [
        (
            "<dl><dt>Firefox</dt><dd>A</dd><dd>B</dd></dl>",
            "* Firefox\n\n  * A\n  * B\n"
        ),
        (
            "<table><!-- a --><tr><th>Head</th><!-- b --></tr>"
                + "<!-- c --><tr><!-- d --><td>Data</td></tr></table>",
            "| <!-- a -->Head<!-- b --> |\n"
                + "| ------------------------ |\n"
                + "| <!-- c --><!-- d -->Data |\n"
        ),
        (
            "<a href=\"/about\">before<h2>Heading</h2>after</a>",
            "[before](/about)\n\n## [Heading](/about)\n\n[after](/about)\n"
        ),
        (
            "<p>Before.</p><object><p>Fallback</p><ul>"
                + "<li><a href=\"x\">Download</a></li></ul></object><p>After.</p>",
            "Before.\n\nFallback\n\n* [Download](x)\n\nAfter.\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(fixture.html)
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func honorsUpstreamTextAndPunctuationOptions() throws {
    let fixtures: [(html: String, options: [String: Any], expected: String)] = [
        (
            "<label><input type=\"checkbox\"> No</label> "
                + "<label><input type=\"radio\" checked> Yes</label>",
            ["unchecked": "✗", "checked": "✓"],
            "✗ No ✓ Yes\n"
        ),
        (
            "<q>alpha <q>bravo <q>charlie</q></q></q>",
            ["quotes": ["«»", "‹›"]],
            "«alpha ‹bravo «charlie»›»\n"
        ),
        (
            "Hello\nWorld.",
            ["newlines": true],
            "Hello\nWorld.\n"
        ),
    ]

    for fixture in fixtures {
        let actual = try featureConverter.conversion(
            fixture.html,
            options: fixture.options
        )
        #expect(
            actual == fixture.expected,
            "Expected \(fixture.expected.debugDescription), got \(actual.debugDescription)"
        )
    }
}

@Test func preservesNewlinesWhereMarkdownAllowsThem() throws {
    let html = """
    <p>one
    two</p>
    <h1>break<br>in h1</h1>
    <h3>break
    in h3</h3>
    <table><tr><th>Heading
    cell</th></tr><tr><td>Data<br>cell</td></tr></table>
    """
    let expected = """
    one
    two

    break\\
    in h1
    =====

    ### break&#xA;in h3

    | Heading&#xA;cell |
    | ---------------- |
    | Data cell        |
    """

    #expect(
        try featureConverter.conversion(html, options: ["newlines": true])
            == expected + "\n"
    )
}

@Test func preservesNestedTableCellBoundaries() throws {
    let html = """
    <table><tr><td><table>
    <tr><td>a</td><td>b</td></tr>
    <tr><td>c</td><td>d</td></tr>
    </table></td><td>outer</td></tr></table>
    """
    let expected = """
    |             |       |
    | ----------- | ----- |
    | a\tb&#xA;c\td | outer |
    """

    let actual = try featureConverter.conversion(html)
    #expect(
        actual == expected + "\n",
        "Expected \(expected.debugDescription), got \(actual.debugDescription)"
    )
}

@Test func mergesImplicitParagraphsAcrossStraddlingInlineElements() throws {
    let html = """
    Alpha <a href="about.html">Bravo<h1>Charlie</h1>Delta</a> Echo
    <object>Fallback<ul><li>Download</li></ul>Alternative</object> Tail
    """
    let expected = """
    Alpha [Bravo](about.html)

    # [Charlie](about.html)

    [Delta](about.html) Echo Fallback

    * Download

    Alternative Tail
    """

    #expect(try featureConverter.conversion(html) == expected + "\n")
}
