import Foundation
import Testing
@testable import ElisCore

struct PhoneLinkTitleFilterTests {
    let roleBel = Data("\u{1B}]2;zmx-role;n0nce:leader:1\u{07}".utf8)
    let roleST = Data("\u{1B}]2;zmx-role;n0nce:follower:2\u{1B}\\".utf8)

    var stream: Data { Data("a".utf8) + roleBel + Data("b".utf8) + roleST + Data("c".utf8) }

    @Test func dropsARoleTitle() {
        var filter = PhoneLinkTitleFilter()
        #expect(filter.filter(stream) == Data("abc".utf8))
    }

    @Test func dropsATitleSplitAcrossChunks() {
        for cut in 0...stream.count {
            var filter = PhoneLinkTitleFilter()
            let out = filter.filter(stream.prefix(cut)) + filter.filter(stream.dropFirst(cut))
            #expect(out == Data("abc".utf8), "cut at \(cut)")
        }
        var filter = PhoneLinkTitleFilter()
        let out = stream.reduce(into: Data()) { $0 += filter.filter(Data([$1])) }
        #expect(out == Data("abc".utf8))
    }

    @Test func keepsOtherTitles() {
        let other = Data("x\u{1B}]2;vim\u{07}\u{1B}]0;zmx-role;n:leader:1\u{07}\u{1B}[31mred\u{1B}\\y\u{1B}".utf8)
        var whole = PhoneLinkTitleFilter()
        #expect(whole.filter(other) + whole.filter(Data("z".utf8)) == other + Data("z".utf8))
        var bytewise = PhoneLinkTitleFilter()
        let out = (other + Data("z".utf8)).reduce(into: Data()) { $0 += bytewise.filter(Data([$1])) }
        #expect(out == other + Data("z".utf8))
    }

    @Test func capsPendingBytes() {
        let unfinished = Data("\u{1B}]2;zmx-role;".utf8) + Data(repeating: 0x78, count: 600)
        var filter = PhoneLinkTitleFilter()
        var fed = 0
        var passed = 0
        for byte in unfinished {
            fed += 1
            passed += filter.filter(Data([byte])).count
            #expect(fed - passed <= 512)
        }
        #expect(passed == unfinished.count)
        #expect(filter.filter(Data("q".utf8)) == Data("q".utf8))
    }
}
