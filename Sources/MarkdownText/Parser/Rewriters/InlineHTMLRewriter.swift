//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// Rewrites supported inline raw-HTML tags into their Markdown equivalents so
/// they render instead of being dropped by inline conversion.
///
/// Supported mappings:
/// - `<br>` / `<br/>` → line break, `<wbr>` → zero-width space
/// - `<b>` / `<strong>` → strong, `<i>` / `<em>` → emphasis
/// - `<s>` / `<del>` / `<strike>` → strikethrough
/// - `<u>` / `<ins>` → underline, `<mark>` → highlight
/// - `<sub>` / `<sup>` → sub/superscript
/// - `<code>` / `<kbd>` / `<samp>` / `<tt>` → inline code
/// - `<a href="…">` → link
///
/// Comments are dropped. Unsupported or unmatched tags render as literal text
/// so their source stays visible. An open tag with no matching close applies
/// to the rest of the inline container (browser-style auto-close), which keeps
/// streamed documents sensible while a tag is still arriving.
final class InlineHTMLRewriter: MarkupRewriter {

  private enum Tag {
    case open(name: String, attributes: String)
    case close(name: String)
    case comment
    case other
  }

  private static let pairedTags: Set<String> = [
    "b", "strong", "i", "em", "s", "del", "strike",
    "u", "ins", "mark", "sub", "sup",
    "code", "kbd", "samp", "tt", "a"
  ]

  private static let hrefRegex = try? Regex(#"href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

  func visitParagraph(_ paragraph: Paragraph) -> Markup? { rewriteInlineChildren(paragraph) }
  func visitHeading(_ heading: Heading) -> Markup? { rewriteInlineChildren(heading) }
  func visitTableCell(_ tableCell: Table.Cell) -> Markup? { rewriteInlineChildren(tableCell) }
  func visitEmphasis(_ emphasis: Emphasis) -> Markup? { rewriteInlineChildren(emphasis) }
  func visitStrong(_ strong: Strong) -> Markup? { rewriteInlineChildren(strong) }
  func visitStrikethrough(_ strikethrough: Strikethrough) -> Markup? { rewriteInlineChildren(strikethrough) }
  func visitLink(_ link: Link) -> Markup? { rewriteInlineChildren(link) }
  func visitInlineAttributes(_ attributes: InlineAttributes) -> Markup? { rewriteInlineChildren(attributes) }
  func visitImage(_ image: Image) -> Markup? { rewriteInlineChildren(image) }

  /// Recursively visits the container's children first, then rewrites the tag
  /// sequences at this level. Containers without `InlineHTML` are returned
  /// unchanged so untouched subtrees keep their identity.
  private func rewriteInlineChildren<Container: InlineContainer & Markup>(_ container: Container) -> Markup? {
    guard Self.containsInlineHTML(container) else { return container }
    // `defaultVisit` is `mutating` on the non-class-bound visitor protocol, so
    // it must be called through a variable; `self` is a class reference here.
    var mutableSelf = self
    guard var visited = mutableSelf.defaultVisit(container) as? Container else { return container }
    visited.setInlineChildren(process(Array(visited.children)))
    return visited
  }

  /// Whether the subtree contains any `InlineHTML` node. Used to prune
  /// containers (and whole documents) that need no rewriting.
  static func containsInlineHTML(_ markup: Markup) -> Bool {
    markup.children.contains { $0 is InlineHTML || containsInlineHTML($0) }
  }

  private func process(_ input: [Markup]) -> [InlineMarkup] {
    var output: [InlineMarkup] = []
    var index = 0
    while index < input.count {
      guard let html = input[index] as? InlineHTML else {
        if let markup = input[index] as? InlineMarkup {
          output.append(markup)
        }
        index += 1
        continue
      }
      switch classify(html) {
      case .comment:
        index += 1
      case .other, .close:
        output.append(Text(html.rawHTML))
        index += 1
      case .open(let name, let attributes):
        if name == "br" {
          output.append(LineBreak())
          index += 1
          continue
        }
        if name == "wbr" {
          output.append(Text("\u{200B}"))
          index += 1
          continue
        }
        guard Self.pairedTags.contains(name) else {
          output.append(Text(html.rawHTML))
          index += 1
          continue
        }
        if let closeIndex = findClosingIndex(named: name, in: input, from: index + 1) {
          let inner = process(Array(input[(index + 1)..<closeIndex]))
          if let wrapped = wrapPair(name: name, attributes: attributes, inner: inner) {
            output.append(wrapped)
          } else {
            output.append(Text(html.rawHTML))
            output.append(contentsOf: inner)
            output.append(Text((input[closeIndex] as? InlineHTML)?.rawHTML ?? ""))
          }
          index = closeIndex + 1
        } else {
          let inner = process(Array(input[(index + 1)...]))
          if let wrapped = wrapPair(name: name, attributes: attributes, inner: inner) {
            output.append(wrapped)
          } else {
            output.append(Text(html.rawHTML))
            output.append(contentsOf: inner)
          }
          index = input.count
        }
      }
    }
    return output
  }

  private func classify(_ html: InlineHTML) -> Tag {
    let raw = html.rawHTML.trimmingCharacters(in: .whitespaces)
    if raw.hasPrefix("<!--") { return .comment }
    guard raw.count > 2, raw.hasPrefix("<"), raw.hasSuffix(">") else { return .other }
    var inner = String(raw.dropFirst().dropLast())
    if inner.hasPrefix("/") {
      inner.removeFirst()
      let name = inner.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "/" }).first.map(String.init) ?? ""
      return name.first?.isLetter == true ? .close(name: name.lowercased()) : .other
    }
    // A trailing "/" does not close non-void elements in HTML5, so `<b/>x`
    // behaves like `<b>x`; the tag is still treated as an open.
    if inner.hasSuffix("/") { inner = String(inner.dropLast()) }
    guard let nameEnd = inner.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) else {
      let name = inner.lowercased()
      return name.first?.isLetter == true ? .open(name: name, attributes: "") : .other
    }
    let name = String(inner[..<nameEnd]).lowercased()
    guard name.first?.isLetter == true else { return .other }
    return .open(name: name, attributes: String(inner[nameEnd...]))
  }

  /// Finds the matching `</name>` for an open tag at `start - 1`, counting
  /// nested same-name tags. Other tags do not affect depth, matching how
  /// browsers auto-close interleaved markup (the stray closer then renders
  /// literally at the outer level).
  private func findClosingIndex(named name: String, in input: [Markup], from start: Int) -> Int? {
    var depth = 0
    for index in start..<input.count {
      guard let html = input[index] as? InlineHTML else { continue }
      switch classify(html) {
      case .open(let tagName, _) where tagName == name:
        depth += 1
      case .close(let tagName) where tagName == name:
        if depth == 0 { return index }
        depth -= 1
      default:
        continue
      }
    }
    return nil
  }

  /// Wraps the processed children of a matched tag pair, or returns `nil` when
  /// the pair cannot be represented (the caller then renders it literally).
  private func wrapPair(name: String, attributes: String, inner: [InlineMarkup]) -> InlineMarkup? {
    switch name {
    case "b", "strong":
      return Strong(inner)
    case "i", "em":
      return Emphasis(inner)
    case "s", "del", "strike":
      return Strikethrough(inner)
    case "u", "ins":
      return attributeWrap("underline", inner)
    case "mark":
      return attributeWrap("highlight", inner)
    case "sub":
      return attributeWrap("subscript", inner)
    case "sup":
      return attributeWrap("superscript", inner)
    case "code", "kbd", "samp", "tt":
      return InlineCode(inner.map { $0.plainText }.joined())
    case "a":
      guard let href = hrefValue(in: attributes),
            let children = recurring(inner) else { return nil }
      return Link(destination: href, children)
    default:
      return nil
    }
  }

  /// `InlineAttributes` children must be `RecurringInlineMarkup`, so stacked
  /// attribute tags (`<u><sup>x</sup></u>`) compose by merging keys into a
  /// single node. A non-recurring child makes the pair render literally.
  private func attributeWrap(_ key: String, _ inner: [InlineMarkup]) -> InlineMarkup? {
    if inner.count == 1, let nested = inner.first as? InlineAttributes {
      let children = Array(nested.children).compactMap { $0 as? (any RecurringInlineMarkup) }
      guard children.count == nested.childCount else { return nil }
      return InlineAttributes(attributes: mergedAttributes(nested.attributes, key: key), children)
    }
    guard let children = recurring(inner) else { return nil }
    return InlineAttributes(attributes: "{\(key):true}", children)
  }

  private func mergedAttributes(_ attributes: String, key: String) -> String {
    guard attributes.hasSuffix("}") else { return attributes }
    return String(attributes.dropLast()) + ",\(key):true}"
  }

  private func recurring(_ inner: [InlineMarkup]) -> [any RecurringInlineMarkup]? {
    let children = inner.compactMap { $0 as? (any RecurringInlineMarkup) }
    return children.count == inner.count ? children : nil
  }

  private func hrefValue(in attributes: String) -> String? {
    guard let regex = Self.hrefRegex, let match = attributes.firstMatch(of: regex) else { return nil }
    for index in 1...3 {
      if let substring = match.output[index].substring {
        return String(substring)
      }
    }
    return nil
  }
}
