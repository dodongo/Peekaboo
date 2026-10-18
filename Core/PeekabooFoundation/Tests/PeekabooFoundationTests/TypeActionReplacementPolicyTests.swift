import PeekabooFoundation
import Testing

struct TypeActionReplacementPolicyTests {
    @Test(arguments: ["", "x", " ", "Café e\u{301}", "👩🏽", "☀️", "🇦🇹"])
    func `clear followed by printable literal text remains eligible`(_ text: String) {
        #expect(TypeAction.hasDeterministicReplacementValue([.clear, .text(text)]))
        #expect(TypeAction.hasDeterministicReplacementValue([.clear, .text(""), .text(text), .text("tail")]))
    }

    @Test(arguments: [
        "\u{0}", "\r", "\u{7F}", "\u{85}", "\u{200B}", "\u{200C}",
        "\u{200D}", "\u{202E}", "\u{2066}", "\u{FEFF}", "\u{E0067}", "👩🏽‍💻",
    ])
    func `nonliteral control and format scalars remain ineligible`(_ text: String) {
        #expect(!TypeAction.hasDeterministicReplacementValue([.clear, .text(text)]))
        #expect(!TypeAction.hasDeterministicReplacementValue([.clear, .text("ok"), .text(text)]))
    }

    @Test
    func `literal text and optional leading clear have a deterministic replacement value`() {
        #expect(TypeAction.hasDeterministicReplacementValue([.clear]))
        #expect(!TypeAction.hasDeterministicReplacementValue([]))
        #expect(TypeAction.hasDeterministicReplacementValue([.text("x")]))
        #expect(TypeAction.hasDeterministicReplacementValue([.text("line\nnext\tend")]))
        #expect(TypeAction.hasDeterministicReplacementValue([.text("line"), .key(.return), .key(.tab)]))
        #expect(TypeAction.hasDeterministicReplacementValue([.clear, .key(.return), .key(.tab)]))
        #expect(!TypeAction.hasDeterministicReplacementValue([.text(""), .clear]))
        #expect(!TypeAction.hasDeterministicReplacementValue([.clear, .clear]))
        #expect(!TypeAction.hasDeterministicReplacementValue([.clear, .text("x"), .clear]))
        for key in [SpecialKey.space, .leftArrow, .delete] {
            #expect(!TypeAction.hasDeterministicReplacementValue([.clear, .key(key)]))
        }
    }
}
