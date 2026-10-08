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
