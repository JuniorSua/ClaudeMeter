import Testing
import Foundation
@testable import ClaudeMeter

struct HumanFormattersTests {
    @Test func tokenFormatting() {
        #expect(HumanFormatters.tokens(0) == "0")
        #expect(HumanFormatters.tokens(999) == "999")
        #expect(HumanFormatters.tokens(1200) == "1.2k")
        #expect(HumanFormatters.tokens(18_420) == "18k")
        #expect(HumanFormatters.tokens(102_300) == "102k")
        #expect(HumanFormatters.tokens(1_400_000) == "1.4M")
        #expect(HumanFormatters.tokens(2_000_000) == "2M")
    }

    @Test func costFormatting() {
        #expect(HumanFormatters.cost(Decimal(string: "0.01")!, estimated: false) == "$0.01")
        #expect(HumanFormatters.cost(Decimal(string: "1.23")!, estimated: false) == "$1.23")
        #expect(HumanFormatters.cost(Decimal(string: "0.42")!, estimated: true) == "~$0.42")
    }

    @Test func durationFormatting() {
        #expect(HumanFormatters.duration(14 * 60) == "14m")
        #expect(HumanFormatters.duration(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(HumanFormatters.duration(27 * 3600) == "1d 3h")
        #expect(HumanFormatters.duration(2 * 3600) == "2h")
    }

    @Test func percentFormatting() {
        #expect(HumanFormatters.percent(42.3) == "42%")
        #expect(HumanFormatters.percent(99.6) == "100%")
    }

    @Test func tokensExact() {
        #expect(HumanFormatters.tokensExact(18420) == "18,420")
    }
}
