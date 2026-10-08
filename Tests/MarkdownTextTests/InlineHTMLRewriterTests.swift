//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import Markdown
import XCTest

final class InlineHTMLRewriterTests: XCTestCase {

  private let parser = MarkdownParserImpl()

  /// Parses `text` through the full pipeline and returns the rendered
  /// paragraph's attributed content.
  private func renderedParagraph(_ text: String) async -> NSMutableAttributedString? {
    let renderables = await renderables(text)
    guard case .paragraph(_, let content) = renderables.first else { return nil }
    return content
  }

  private func renderables(_ text: String) async -> [MarkdownRenderable] {
    await parser.parse(text: text, config: .default).renderables
  }

  // MARK: - Inline containers

  func test_bold_tag_renders_strong() async {
    let content = await renderedParagraph("a <b>bold</b> c")
    XCTAssertEqual(content?.string, "a bold c")
    let boldFont = content?.attribute(.font, at: 2, effectiveRange: nil) as? MDFont
    let plainFont = content?.attribute(.font, at: 0, effectiveRange: nil) as? MDFont
    XCTAssertNotNil(boldFont)
    XCTAssertNotEqual(boldFont, plainFont)
  }

  func test_italic_tag_renders_emphasis() async {
    let content = await renderedParagraph("a <i>x</i>")
    XCTAssertEqual(content?.string, "a x")
  }

  func test_strikethrough_tag_adds_strike_attribute() async {
    let content = await renderedParagraph("a <s>gone</s>")
    XCTAssertEqual(content?.string, "a gone")
    let strike = content?.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int
    XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
  }

  func test_br_tag_renders_line_break() async {
    let content = await renderedParagraph("one<br>two")
    XCTAssertEqual(content?.string, "one\ntwo")
  }

  func test_kbd_tag_renders_inline_code() async {
    let content = await renderedParagraph("press <kbd>Cmd</kbd>")
    XCTAssertEqual(content?.string, "press Cmd")
    let background = content?.attribute(.backgroundColor, at: 6, effectiveRange: nil)
    XCTAssertNotNil(background)
  }

  func test_sub_and_sup_tags_set_baseline_offsets() async {
    let content = await renderedParagraph("H<sub>2</sub>O x<sup>2</sup>")
    XCTAssertEqual(content?.string, "H2O x2")
    let sub = content?.attribute(.baselineOffset, at: 1, effectiveRange: nil) as? CGFloat
    XCTAssertNotNil(sub)
    XCTAssertLessThan(sub ?? 0, 0)
    let sup = content?.attribute(.baselineOffset, at: 5, effectiveRange: nil) as? CGFloat
    XCTAssertNotNil(sup)
    XCTAssertGreaterThan(sup ?? 0, 0)
  }

  func test_u_tag_underlines() async {
    let content = await renderedParagraph("a <u>under</u>")
    let underline = content?.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int
    XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
  }

  func test_mark_tag_highlights() async {
    let content = await renderedParagraph("a <mark>hi</mark>")
    let background = content?.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? MDColor
    XCTAssertNotNil(background)
  }

  func test_anchor_tag_renders_link() async {
    let content = await renderedParagraph("see <a href=\"https://example.com\">site</a>")
    XCTAssertEqual(content?.string, "see site")
    let link = content?.attribute(.link, at: 4, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://example.com")
  }

  func test_nested_attribute_tags_compose() async {
    let content = await renderedParagraph("a <u><sup>x</sup></u>")
    let underline = content?.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int
    XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    let sup = content?.attribute(.baselineOffset, at: 2, effectiveRange: nil) as? CGFloat
    XCTAssertGreaterThan(sup ?? 0, 0)
  }

  func test_tag_inside_strong_keeps_bold() async {
    let content = await renderedParagraph("**<u>x</u>**")
    XCTAssertEqual(content?.string, "x")
    let underline = content?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
    XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
  }

  // MARK: - Graceful degradation

  func test_unclosed_tag_applies_to_end_of_container() async {
    let content = await renderedParagraph("a <b>bold")
    XCTAssertEqual(content?.string, "a bold")
  }

  func test_stray_close_tag_renders_literally() async {
    let content = await renderedParagraph("a </b> c")
    XCTAssertEqual(content?.string, "a </b> c")
  }

  func test_unknown_tag_renders_literally() async {
    let content = await renderedParagraph("a <span>x</span> b")
    XCTAssertEqual(content?.string, "a <span>x</span> b")
  }

  func test_comment_is_dropped() async {
    let content = await renderedParagraph("a <!-- hidden --> b")
    XCTAssertEqual(content?.string, "a  b")
  }

  func test_anchor_without_href_renders_literally() async {
    let content = await renderedParagraph("a <a>x</a>")
    XCTAssertEqual(content?.string, "a <a>x</a>")
  }

  func test_data_href_does_not_produce_a_link() async {
    let content = await renderedParagraph("a <a data-href=\"https://evil.example\">x</a>")
    XCTAssertEqual(content?.string, "a <a data-href=\"https://evil.example\">x</a>")
    let link = content?.attribute(.link, at: 2, effectiveRange: nil)
    XCTAssertNil(link)
  }

  func test_uppercase_href_produces_link() async {
    let content = await renderedParagraph("a <a HREF=\"https://example.com\">x</a>")
    XCTAssertEqual(content?.string, "a x")
    let link = content?.attribute(.link, at: 2, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://example.com")
  }

  func test_quoted_attribute_containing_href_is_skipped() async {
    let content = await renderedParagraph("a <a title=\"v href='x'\" href=\"https://real.example\">x</a>")
    let link = content?.attribute(.link, at: 2, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://real.example")
  }

  func test_href_entities_are_decoded() async {
    let content = await renderedParagraph("a <a href=\"https://x.example?a=1&amp;b=2\">x</a>")
    let link = content?.attribute(.link, at: 2, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://x.example?a=1&b=2")
  }

  func test_stray_br_close_tag_renders_line_break() async {
    let content = await renderedParagraph("a</br>b")
    XCTAssertEqual(content?.string, "a\nb")
  }

  func test_standalone_tag_block_renders_literally() async {
    // `<b>` on its own line is an HTML block (cmark type 7); it must not lose text.
    let renderables = await renderables("intro\n\n<b>\nHello world\n</b>\n\noutro")
    let allText = renderables.compactMap { renderable -> String? in
      guard case .paragraph(_, let content) = renderable else { return nil }
      return content.string
    }.joined()
    XCTAssertTrue(allText.contains("Hello world"))
    XCTAssertTrue(allText.contains("intro"))
  }

  func test_underline_wraps_text_around_a_link() async {
    let content = await renderedParagraph("<u>before <a href=\"https://x.example\">mid</a> after</u>")
    XCTAssertEqual(content?.string, "before mid after")
    let underlineBefore = content?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
    XCTAssertEqual(underlineBefore, NSUnderlineStyle.single.rawValue)
    let link = content?.attribute(.link, at: 7, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://x.example")
    let underlineAfter = content?.attribute(.underlineStyle, at: 10, effectiveRange: nil) as? Int
    XCTAssertEqual(underlineAfter, NSUnderlineStyle.single.rawValue)
  }

  func test_link_wraps_attribute_styled_text() async {
    let content = await renderedParagraph("<a href=\"https://x.example\"><u>x</u></a>")
    XCTAssertEqual(content?.string, "x")
    let link = content?.attribute(.link, at: 0, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://x.example")
  }

  func test_code_tag_flattens_nested_inline_code() async {
    let content = await renderedParagraph("<code>a `b` c</code>")
    XCTAssertEqual(content?.string, "a b c")
  }

  func test_deeply_unclosed_tags_do_not_crash() async {
    let opens = String(repeating: "<b>", count: 500)
    let content = await renderedParagraph("a \(opens)x")
    XCTAssertNotNil(content?.string)
  }

  // MARK: - Non-regression

  func test_document_without_html_is_untouched() async {
    let renderables = await renderables("plain **bold** text")
    guard case .paragraph = renderables.first else {
      return XCTFail("expected paragraph")
    }
  }

  func test_html_inside_code_span_is_not_rewritten() async {
    let content = await renderedParagraph("`<b>x</b>`")
    XCTAssertEqual(content?.string, "<b>x</b>")
  }
}
