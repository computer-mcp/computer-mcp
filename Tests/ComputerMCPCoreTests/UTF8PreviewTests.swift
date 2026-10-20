import ComputerMCPCore
import Testing

struct UTF8PreviewTests {
  @Test
  func previewsKeepGraphemeBoundaries() {
    let text = "e\u{301}🙂x"
    #expect(utf8Preview(text, maxBytes: 2).text == "")
    #expect(utf8Preview(text, maxBytes: 3).text == "e\u{301}")
    #expect(utf8Preview(text, maxBytes: 7).text == "e\u{301}🙂")
    #expect(utf8Preview(text, maxBytes: 7).truncated)
    #expect(!utf8Preview(text, maxBytes: 8).truncated)
  }
}
