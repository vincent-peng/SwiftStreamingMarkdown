//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// Rewrites paired inline delimiter runs into `InlineAttributes` nodes so
/// syntax like `==highlight==` renders instead of staying literal text.
///
/// Each `DelimiterSpec` describes one marker. `Text` content is scanned for
/// maximal runs of the marker's character; a run of length `n` yields
/// `n % marker.count` literal characters followed by `n / marker.count`
/// marker tokens, so `===x===` produces `=` + marker + `x` + marker + `=`.
///
/// All markers in a run share the run's flanking: a marker can open when a
/// non-whitespace character follows the run and can close when a
/// non-whitespace character precedes it. Scanning left to right with an
/// opener stack pairs each closer with the most recent unmatched opener, so
/// `====x====` nests and still highlights `x`. Markers that never pair stay
/// as literal text, which keeps streamed documents sensible while a closing
/// delimiter is still arriving.
///
/// `Link`, `Image`, and `InlineAttributes` containers are visited but never
/// paired at their own level: their children must stay
/// `RecurringInlineMarkup`, so `==` there remains literal.
///
/// Known limitation: a backslash-escaped `\==` arrives as a literal `=` in
/// `Text` content because cmark strips the escape during parsing, so
/// `\==x==` still highlights. The two forms are indistinguishable at this
/// layer.
final class InlineDelimiterRewriter: MarkupRewriter {

  /// Describes one inline delimiter pair and the attribute it produces.
  struct DelimiterSpec {
    /// The repeated-character marker text, e.g. `"=="`.
    let marker: String
    /// The `InlineAttributes` key set to `true` on wrapped content.
    let attribute: String
    /// Whether the wrapped range may contain whitespace. `false` keeps the
    /// markers of a pair like `^a b^` literal.
    let allowsInnerWhitespace: Bool

    /// `==highlight==`; inner whitespace is allowed.
    static let highlight = DelimiterSpec(marker: "==", attribute: "highlight", allowsInnerWhitespace: true)
  }

  /// Maximum nested-pair depth transformed before markers are emitted
  /// literally. Bounds recursion on adversarial inputs like hundreds of
  /// nested `====...====` runs.
  private static let maxDepth = 64

  private let specs: [DelimiterSpec]

  init(specs: [DelimiterSpec]) {
    self.specs = specs
  }

  func visitParagraph(_ paragraph: Paragraph) -> Markup? { rewriteInlineChildren(paragraph) }
  func visitHeading(_ heading: Heading) -> Markup? { rewriteInlineChildren(heading) }
  func visitTableCell(_ tableCell: Table.Cell) -> Markup? { rewriteInlineChildren(tableCell) }
  func visitEmphasis(_ emphasis: Emphasis) -> Markup? { rewriteInlineChildren(emphasis) }
  func visitStrong(_ strong: Strong) -> Markup? { rewriteInlineChildren(strong) }
  func visitStrikethrough(_ strikethrough: Strikethrough) -> Markup? { rewriteInlineChildren(strikethrough) }
  func visitLink(_ link: Link) -> Markup? { rewriteInlineChildren(link) }
  func visitImage(_ image: Image) -> Markup? { rewriteInlineChildren(image) }
  func visitInlineAttributes(_ attributes: InlineAttributes) -> Markup? { rewriteInlineChildren(attributes) }

  /// A flattened sibling: a literal text fragment, a run remainder that is
  /// also literal text but carries provenance for flanking and wrap
  /// boundaries, an opaque non-`Text` node, or one delimiter marker token
  /// stamped with its run's flanking.
  private enum Piece {
    case text(String)
    case remainder(String)
    case node(InlineMarkup)
    case marker(specIndex: Int, canOpen: Bool, canClose: Bool)
  }

  /// Recursively visits the container's children first, then pairs delimiter
  /// markers at this level. Containers without a spec marker in any `Text`
  /// descendant are returned unchanged so untouched subtrees keep identity.
  private func rewriteInlineChildren<Container: InlineContainer & Markup>(_ container: Container) -> Markup? {
    guard Self.containsDelimiter(container, specs: specs) else { return container }
    // `defaultVisit` is `mutating` on the non-class-bound visitor protocol, so
    // it must be called through a variable; `self` is a class reference here.
    var mutableSelf = self
    guard var visited = mutableSelf.defaultVisit(container) as? Container else { return container }
    // `Link`, `Image`, and `InlineAttributes` only allow `RecurringInlineMarkup`
    // children, so markers at their level are never consumed; deeper
    // containers have already been processed by `defaultVisit`.
    if visited is Link || visited is Image || visited is InlineAttributes {
      return visited
    }
    visited.setInlineChildren(process(Array(visited.children)))
    return visited
  }

  /// Whether the subtree contains a `Text` node holding a spec marker. Used
  /// to prune containers (and whole documents) that need no rewriting.
  static func containsDelimiter(_ markup: Markup, specs: [DelimiterSpec]) -> Bool {
    markup.children.contains { child in
      if let text = child as? Text, specs.contains(where: { text.string.contains($0.marker) }) {
        return true
      }
      return containsDelimiter(child, specs: specs)
    }
  }

  /// Pairs the container's direct children. When no marker pair exists the
  /// input passes through unchanged so untouched subtrees keep identity.
  private func process(_ input: [Markup]) -> [InlineMarkup] {
    var pieces = tokenize(input)
    applyFlanking(&pieces)
    let closeForOpen = pairedCloses(in: pieces)
    guard !closeForOpen.isEmpty else {
      return input.compactMap { $0 as? InlineMarkup }
    }
    return emit(pieces, in: 0..<pieces.count, closeForOpen: closeForOpen, depth: 0)
  }

  /// Splits sibling inline nodes into pieces. `Text` runs of a marker
  /// character become a `remainder` of `n % marker.count` characters plus
  /// `n / marker.count` marker tokens; every other node stays opaque.
  private func tokenize(_ input: [Markup]) -> [Piece] {
    var pieces: [Piece] = []
    for child in input {
      guard let text = child as? Text else {
        if let inline = child as? InlineMarkup {
          pieces.append(.node(inline))
        } else {
          pieces.append(.text((child as? PlainTextConvertibleMarkup)?.plainText ?? ""))
        }
        continue
      }
      let string = text.string
      var index = string.startIndex
      var literalStart = index
      while index < string.endIndex {
        guard let specIndex = specs.firstIndex(where: { $0.marker.first == string[index] }) else {
          index = string.index(after: index)
          continue
        }
        var runEnd = string.index(after: index)
        while runEnd < string.endIndex, string[runEnd] == string[index] {
          runEnd = string.index(after: runEnd)
        }
        if literalStart < index {
          pieces.append(.text(String(string[literalStart..<index])))
        }
        let runLength = string.distance(from: index, to: runEnd)
        let markerLength = specs[specIndex].marker.count
        let literalCount = runLength % markerLength
        if literalCount > 0 {
          pieces.append(.remainder(String(repeating: string[index], count: literalCount)))
        }
        for _ in 0..<(runLength / markerLength) {
          pieces.append(.marker(specIndex: specIndex, canOpen: false, canClose: false))
        }
        index = runEnd
        literalStart = runEnd
      }
      if literalStart < string.endIndex {
        pieces.append(.text(String(string[literalStart...])))
      }
    }
    return pieces
  }

  /// Computes flanking once per marker run and stamps it onto every token.
  /// A run's `canOpen` requires a non-whitespace character after the last
  /// marker; `canClose` requires a non-whitespace character before the run,
  /// which sits before any `remainder` the run emitted.
  private func applyFlanking(_ pieces: inout [Piece]) {
    var index = 0
    while index < pieces.count {
      guard case .marker = pieces[index] else {
        index += 1
        continue
      }
      var runEnd = index + 1
      while runEnd < pieces.count, case .marker = pieces[runEnd] {
        runEnd += 1
      }
      var runStart = index
      while runStart > 0, case .remainder = pieces[runStart - 1] {
        runStart -= 1
      }
      let canClose = runStart > 0 && lastCharacter(of: pieces[runStart - 1])?.isWhitespace == false
      let canOpen = runEnd < pieces.count && firstCharacter(of: pieces[runEnd])?.isWhitespace == false
      for markerIndex in index..<runEnd {
        guard case .marker(let specIndex, _, _) = pieces[markerIndex] else { continue }
        pieces[markerIndex] = .marker(specIndex: specIndex, canOpen: canOpen, canClose: canClose)
      }
      index = runEnd
    }
  }

  /// Pairs each closer with the most recent unmatched opener of the same
  /// spec and returns `open index -> close index`. A marker that can both
  /// open and close prefers closing when an opener exists.
  private func pairedCloses(in pieces: [Piece]) -> [Int: Int] {
    var openers: [[Int]] = specs.map { _ in [] }
    var closeForOpen: [Int: Int] = [:]
    for (index, piece) in pieces.enumerated() {
      guard case .marker(let specIndex, let canOpen, let canClose) = piece else { continue }
      if canClose, let openIndex = openers[specIndex].popLast() {
        closeForOpen[openIndex] = index
      } else if canOpen {
        openers[specIndex].append(index)
      }
    }
    return closeForOpen
  }

  /// Emits the piece range, wrapping each paired open/close span in an
  /// `InlineAttributes` node. Pairs nest, so an outer wrap absorbs an inner
  /// `InlineAttributes` as plain text; unpaired markers become literal text.
  private func emit(_ pieces: [Piece], in range: Range<Int>, closeForOpen: [Int: Int], depth: Int) -> [InlineMarkup] {
    var output: [InlineMarkup] = []
    var index = range.lowerBound
    while index < range.upperBound {
      switch pieces[index] {
      case .text(let string), .remainder(let string):
        output.append(Text(string))
        index += 1
      case .node(let node):
        output.append(node)
        index += 1
      case .marker(let specIndex, _, _):
        let spec = specs[specIndex]
        guard let close = closeForOpen[index], depth < Self.maxDepth else {
          output.append(Text(spec.marker))
          index += 1
          continue
        }
        // `remainder` pieces at the wrap boundary belong to the consumed
        // markers' own runs, so they emit outside: `===x===` highlights `x`
        // and leaves one literal `=` on each side.
        var innerStart = index + 1
        var innerEnd = close
        var leading: [String] = []
        while innerStart < innerEnd, case .remainder(let string) = pieces[innerStart] {
          leading.append(string)
          innerStart += 1
        }
        var trailing: [String] = []
        while innerEnd > innerStart, case .remainder(let string) = pieces[innerEnd - 1] {
          trailing.insert(string, at: 0)
          innerEnd -= 1
        }
        let inner = emit(pieces, in: innerStart..<innerEnd, closeForOpen: closeForOpen, depth: depth + 1)
        let containsWhitespace = inner.contains { markup in
          markup.plainText.contains { $0.isWhitespace }
        }
        output.append(contentsOf: leading.map { Text($0) })
        if spec.allowsInnerWhitespace || !containsWhitespace {
          output.append(contentsOf: attributeWrap("\(spec.attribute):true", inner))
        } else {
          output.append(Text(spec.marker))
          output.append(contentsOf: inner)
          output.append(Text(spec.marker))
        }
        output.append(contentsOf: trailing.map { Text($0) })
        index = close + 1
      }
    }
    return output
  }

  /// `InlineAttributes` children must be `RecurringInlineMarkup`, so a
  /// generated wrap cannot contain a nested `InlineAttributes` node. Runs
  /// around nested attribute nodes are split instead: each nested node's
  /// children are re-wrapped under the union of both key sets, which keeps
  /// e.g. `==a <sup>b</sup>==` as highlighted text with a superscripted `b`
  /// rather than dropping the inner style. Other non-recurring children
  /// (`Link`, `Image`) degrade to their plain text inside the current run.
  private func attributeWrap(_ key: String, _ inner: [InlineMarkup]) -> [InlineMarkup] {
    var output: [InlineMarkup] = []
    var run: [any RecurringInlineMarkup] = []

    func flushRun() {
      guard !run.isEmpty else { return }
      output.append(InlineAttributes(attributes: "{\(key)}", run))
      run = []
    }

    for markup in inner {
      if let attributes = markup as? InlineAttributes {
        flushRun()
        if let mergedKey = mergedKeys(key, inner: attributes.attributes) {
          output.append(contentsOf: attributeWrap(mergedKey, attributes.children.compactMap { $0 as? InlineMarkup }))
        } else {
          output.append(attributes)
        }
      } else if let recurring = markup as? (any RecurringInlineMarkup) {
        run.append(recurring)
      } else {
        run.append(Text(markup.plainText))
      }
    }
    flushRun()
    return output
  }

  /// Keys like `subscript:true` the renderer understands. Attribute nodes
  /// generated by this rewriter and `InlineHTMLRewriter` always match;
  /// anything else keeps its original attributes.
  private static let enabledKeyRegex = try? Regex(#"(?:^|[,{}\s])([a-zA-Z]+)\s*:\s*true\b"#)

  /// Union of `base` and the inner node's keys (`"a:true"` comma-separated
  /// contents without braces). Returns `nil` when the inner attribute string
  /// holds no recognized keys, so the node can pass through unchanged.
  private func mergedKeys(_ base: String, inner: String) -> String? {
    guard let regex = Self.enabledKeyRegex else { return nil }
    var merged = base
    var found = false
    for match in inner.matches(of: regex) {
      guard let key = match.output[1].substring else { continue }
      let entry = "\(key):true"
      // `{` or `,` boundary avoids prefix false-positives like `sub:` inside
      // `subscript:`.
      if !merged.contains("{\(entry)") && !merged.contains(",\(entry)") {
        merged += ",\(entry)"
      }
      found = true
    }
    return found ? merged : nil
  }

  private func firstCharacter(of piece: Piece) -> Character? {
    switch piece {
    case .text(let string), .remainder(let string):
      return string.first
    case .node(let node):
      return node.plainText.first
    case .marker(let specIndex, _, _):
      return specs[specIndex].marker.first
    }
  }

  private func lastCharacter(of piece: Piece) -> Character? {
    switch piece {
    case .text(let string), .remainder(let string):
      return string.last
    case .node(let node):
      return node.plainText.last
    case .marker(let specIndex, _, _):
      return specs[specIndex].marker.last
    }
  }
}
