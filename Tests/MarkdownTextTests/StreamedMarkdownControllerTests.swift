//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import XCTest

final class StreamedMarkdownControllerTests: XCTestCase {

  private final class StubSource: StreamedMarkdownSource {
    let text: AsyncStream<String>

    init(snapshots: [String]) {
      text = AsyncStream { continuation in
        for snapshot in snapshots {
          continuation.yield(snapshot)
        }
        continuation.finish()
      }
    }
  }

  private func renderOnce(snapshots: [String], config: MarkdownRenderConfig = .default) async -> RenderableDocument {
    let controller = StreamedMarkdownController(source: StubSource(snapshots: snapshots), config: config)
    await controller.start()
    for _ in 0..<200 where controller.markdownToRender.renderables.isEmpty {
      try? await Task.sleep(ms: 5)
    }
    await controller.end()
    return controller.markdownToRender
  }

  func test_partial_trailing_strong_is_speculatively_closed() async {
    let rendered = await renderOnce(snapshots: ["Yeah, this is **cool"])
    XCTAssertEqual(rendered.plainText, "Yeah, this is cool")
  }

  func test_partial_table_header_is_hidden_until_complete() async {
    let rendered = await renderOnce(snapshots: ["intro\n\n| Month | Savings |"])
    XCTAssertFalse(rendered.plainText.contains("Month"))
  }

  func test_complete_markdown_renders_unchanged() async {
    let rendered = await renderOnce(snapshots: ["Hello **world**"])
    XCTAssertEqual(rendered.plainText, "Hello world")
  }
}
