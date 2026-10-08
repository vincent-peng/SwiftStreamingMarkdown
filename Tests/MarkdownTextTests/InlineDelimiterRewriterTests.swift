//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import Markdown
import XCTest

final class InlineDelimiterRewriterTests: XCTestCase {

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

  private func background(at index: Int, in content: NSMutableAttributedString?) -> MDColor? {
    content?.attribute(.backgroundColor, at: index, effectiveRange: nil) as? MDColor
  }

  private func baseline(at index: Int, in content: NSMutableAttributedString?) -> CGFloat {
    CGFloat((content?.attribute(.baselineOffset, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
  }

  // MARK: - Pairing

  func test_simple_highlight() async {
    let content = await renderedParagraph("a ==b== c")
    XCTAssertEqual(content?.string, "a b c")
    XCTAssertNotNil(background(at: 2, in: content))
    XCTAssertNil(background(at: 0, in: content))
    XCTAssertNil(background(at: 4, in: content))
  }

  func test_highlight_whole_paragraph() async {
    let content = await renderedParagraph("==x==")
    XCTAssertEqual(content?.string, "x")
    XCTAssertNotNil(background(at: 0, in: content))
  }

  func test_intraword_highlight() async {
    let content = await renderedParagraph("a==b==c")
    XCTAssertEqual(content?.string, "abc")
    XCTAssertNotNil(background(at: 1, in: content))
    XCTAssertNil(background(at: 0, in: content))
    XCTAssertNil(background(at: 2, in: content))
  }

  func test_marker_touching_spaces_stays_literal() async {
    let content = await renderedParagraph("== x ==")
    XCTAssertEqual(content?.string, "== x ==")
  }

  func test_intraword_marker_touching_spaces_stays_literal() async {
    let content = await renderedParagraph("x == y ==")
    XCTAssertEqual(content?.string, "x == y ==")
  }

  func test_close_marker_preceded_by_space_stays_literal() async {
    let content = await renderedParagraph("==x ==")
    XCTAssertEqual(content?.string, "==x ==")
  }

  func test_open_marker_followed_by_space_stays_literal() async {
    let content = await renderedParagraph("== x==")
    XCTAssertEqual(content?.string, "== x==")
  }

  func test_unclosed_marker_stays_literal() async {
    let content = await renderedParagraph("a ==b")
    XCTAssertEqual(content?.string, "a ==b")
  }

  func test_odd_run_leaves_one_literal_equals() async {
    let content = await renderedParagraph("===x===")
    XCTAssertEqual(content?.string, "=x=")
    XCTAssertNil(background(at: 0, in: content))
    XCTAssertNotNil(background(at: 1, in: content))
    XCTAssertNil(background(at: 2, in: content))
  }

  func test_double_run_nests_and_highlights() async {
    let content = await renderedParagraph("====x====")
    XCTAssertEqual(content?.string, "x")
    XCTAssertNotNil(background(at: 0, in: content))
  }

  func test_nested_highlight_is_absorbed() async {
    let content = await renderedParagraph("==a ==b== c==")
    XCTAssertEqual(content?.string, "a b c")
    for index in 0..<5 {
      XCTAssertNotNil(background(at: index, in: content), "expected highlight at \(index)")
    }
  }

  func test_highlight_wraps_strong() async {
    let content = await renderedParagraph("a ==**b**== c")
    XCTAssertEqual(content?.string, "a b c")
    XCTAssertNotNil(background(at: 2, in: content))
    let boldFont = content?.attribute(.font, at: 2, effectiveRange: nil) as? MDFont
    let plainFont = content?.attribute(.font, at: 0, effectiveRange: nil) as? MDFont
    XCTAssertNotNil(boldFont)
    XCTAssertNotEqual(boldFont, plainFont)
  }

  func test_strong_wraps_highlight() async {
    let content = await renderedParagraph("a **==b==** c")
    XCTAssertEqual(content?.string, "a b c")
    XCTAssertNotNil(background(at: 2, in: content))
    let boldFont = content?.attribute(.font, at: 2, effectiveRange: nil) as? MDFont
    let plainFont = content?.attribute(.font, at: 0, effectiveRange: nil) as? MDFont
    XCTAssertNotNil(boldFont)
    XCTAssertNotEqual(boldFont, plainFont)
  }

  func test_highlight_wraps_html_strong() async {
    let content = await renderedParagraph("==a <b>b</b> c==")
    XCTAssertEqual(content?.string, "a b c")
    for index in 0..<5 {
      XCTAssertNotNil(background(at: index, in: content), "expected highlight at \(index)")
    }
    let boldFont = content?.attribute(.font, at: 2, effectiveRange: nil) as? MDFont
    let plainFont = content?.attribute(.font, at: 0, effectiveRange: nil) as? MDFont
    XCTAssertNotNil(boldFont)
    XCTAssertNotEqual(boldFont, plainFont)
  }

  func test_nested_attribute_nodes_compose() async {
    let content = await renderedParagraph("==a <sup>b</sup> c==")
    XCTAssertEqual(content?.string, "a b c")
    for index in 0..<5 {
      XCTAssertNotNil(background(at: index, in: content), "expected highlight at \(index)")
    }
    XCTAssertGreaterThan(baseline(at: 2, in: content), 0)
    XCTAssertEqual(baseline(at: 0, in: content), 0)
  }

  // MARK: - Constrained containers and code spans

  func test_marker_inside_link_text_stays_literal() async {
    let content = await renderedParagraph("[==x==](https://ex.com)")
    XCTAssertEqual(content?.string, "==x==")
    let link = content?.attribute(.link, at: 0, effectiveRange: nil) as? URL
    XCTAssertEqual(link?.absoluteString, "https://ex.com")
  }

  func test_marker_inside_code_span_stays_literal() async {
    let content = await renderedParagraph("`==x==`")
    XCTAssertEqual(content?.string, "==x==")
  }

  // MARK: - Other blocks

  func test_highlight_in_heading() async {
    let renderables = await renderables("# ==x==")
    guard case .heading(_, let level, let content) = renderables.first else {
      return XCTFail("expected heading")
    }
    XCTAssertEqual(level, 1)
    XCTAssertEqual(content.string, "x")
    XCTAssertNotNil(content.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? MDColor)
  }

  func test_highlight_in_table_cell() async {
    let renderables = await renderables("| head |\n| --- |\n| ==x== |")
    guard case .table(_, _, let rows, _) = renderables.first else {
      return XCTFail("expected table")
    }
    let cell = rows.first?.first
    XCTAssertEqual(cell?.string, "x")
    XCTAssertNotNil(cell?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? MDColor)
  }

  // MARK: - Non-regression

  func test_document_without_markers_is_untouched() async {
    let document = await parser.parse(text: "plain **bold** text")
    XCTAssertEqual(document.debugDescription(), Document(parsing: "plain **bold** text").debugDescription())
  }
}
