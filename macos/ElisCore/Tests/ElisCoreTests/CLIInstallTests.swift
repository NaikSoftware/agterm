import Testing
@testable import ElisCore

struct CLIInstallTests {
    @Test func installPathIsToolUnderInstallDir() {
        #expect(CLIInstall.installPath == "/usr/local/bin/elisctl")
    }

    @Test func shellQuoteWrapsPlainValue() {
        #expect(CLIInstall.shellQuote("/Applications/Elis.app") == "'/Applications/Elis.app'")
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(CLIInstall.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func privilegedCommandLinksSourceToInstallPath() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/Apps/Elis.app/Contents/MacOS/elisctl")
        #expect(cmd == "mkdir -p '/usr/local/bin' && ln -sf '/Apps/Elis.app/Contents/MacOS/elisctl' '/usr/local/bin/elisctl'")
    }

    @Test func privilegedCommandQuotesSourceWithSpaces() {
        let cmd = CLIInstall.privilegedInstallCommand(source: "/My Apps/Elis.app/Contents/MacOS/elisctl")
        #expect(cmd.contains("ln -sf '/My Apps/Elis.app/Contents/MacOS/elisctl' '/usr/local/bin/elisctl'"))
    }
}
