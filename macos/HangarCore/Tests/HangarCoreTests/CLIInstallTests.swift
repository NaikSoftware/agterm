import Testing
@testable import HangarCore

struct CLIInstallTests {
    @Test func installPathIsToolUnderInstallDir() {
        #expect(CLIInstall.installPath == "/usr/local/bin/hangarctl")
    }

    @Test func shellQuoteWrapsPlainValue() {
        #expect(CLIInstall.shellQuote("/Applications/Hangar.app") == "'/Applications/Hangar.app'")
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CLIInstall.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func privilegedCommandLinksSourceToInstallPath() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/Apps/Hangar.app/Contents/MacOS/hangarctl")
        #expect(cmd == "mkdir -p '/usr/local/bin' && ln -sf '/Apps/Hangar.app/Contents/MacOS/hangarctl' '/usr/local/bin/hangarctl'")
    }

    @Test func privilegedCommandQuotesSourceWithSpaces() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/My Apps/Hangar.app/Contents/MacOS/hangarctl")
        #expect(cmd.contains("ln -sf '/My Apps/Hangar.app/Contents/MacOS/hangarctl' '/usr/local/bin/hangarctl'"))
    }
}
