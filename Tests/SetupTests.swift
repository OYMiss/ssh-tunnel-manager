import XCTest
@testable import SSHTunnelCore

final class SetupTests: XCTestCase {
    func testAllThreeDirectionsAndDefaults() throws {
        var setup = TunnelSetup()
        setup.destination = "user@server"
        var command = try SSHCommand(setup.validatedCommand())
        XCTAssertEqual(command.userArguments, ["-L", "127.0.0.1:8080:localhost:80"])
        XCTAssertEqual(command.portSummary, "本地 :8080")
        setup.changeKind(to: .remote)
        command = try SSHCommand(setup.validatedCommand())
        XCTAssertEqual(command.userArguments, ["-R", "127.0.0.1:8080:localhost:3000"])
        XCTAssertEqual(command.portSummary, "远程 :8080")
        setup.changeKind(to: .dynamic)
        command = try SSHCommand(setup.validatedCommand())
        XCTAssertEqual(command.userArguments, ["-D", "127.0.0.1:1080"])
        XCTAssertEqual(command.portSummary, "动态 :1080")
        XCTAssertEqual(command.destination, "user@server")
        XCTAssertFalse(command.userArguments.contains("-p"), "An alias may define a nonstandard SSH port.")
    }

    func testEditPreservesOptionsAndBinding() throws {
        for binding in ["", "127.0.0.1:", "localhost:", "[::1]:"] {
            let original = try SSHCommand("ssh -NT -i '/tmp/key with spaces' -L '\(binding)8080:localhost:80' -p2222 -J jump -o AddressFamily=inet alias")
            var setup = try TunnelSetup(command: original)
            XCTAssertEqual(setup.sshPort, "2222")
            XCTAssertEqual(try SSHCommand(setup.validatedCommand()).userArguments, original.userArguments)
            setup.listenPort = "9090"
            setup.destination = "other-alias"
            let edited = try SSHCommand(setup.validatedCommand())
            XCTAssertEqual(edited.userArguments, ["-i", "/tmp/key with spaces", "-L", "\(binding)9090:localhost:80", "-p", "2222", "-J", "jump", "-o", "AddressFamily=inet"])
            XCTAssertEqual(edited.destination, "other-alias")
        }
    }

    func testConfigStyleForwardAndPortRoundTrip() throws {
        var setup = try TunnelSetup(command: SSHCommand("ssh -o 'Port 2202' -o 'RemoteForward=8080 localhost:3000' -i /tmp/key alias"))
        XCTAssertEqual(setup.kind, .remote)
        XCTAssertEqual(setup.sshPort, "2202")
        setup.targetPort = "4000"
        XCTAssertEqual(try SSHCommand(setup.validatedCommand()).userArguments, ["-p", "2202", "-R", "8080:localhost:4000", "-i", "/tmp/key"])
        setup.sshPort = ""
        XCTAssertFalse(try SSHCommand(setup.validatedCommand()).userArguments.contains("-p"))
        let proxy = try TunnelSetup(command: SSHCommand("ssh -o 'DynamicForward [::1]:1080' alias"))
        XCTAssertEqual(proxy.kind, .dynamic)
        XCTAssertEqual(try SSHCommand(proxy.validatedCommand()).userArguments, ["-D", "[::1]:1080"])
    }

    func testComplexCommandsStayManual() throws {
        for text in ["ssh -L8080:localhost:80 -D1080 alias", "ssh -R1080 alias",
                     "ssh -L0.0.0.0:8080:localhost:80 alias", "ssh -D '*:1080' alias",
                     "ssh -p22 -o Port=2222 -D1080 alias"] {
            XCTAssertThrowsError(try TunnelSetup(command: SSHCommand(text)), text)
        }
    }

    func testInvalidFieldsAndIPv6() throws {
        var setup = TunnelSetup()
        XCTAssertThrowsError(try setup.validatedCommand())
        setup.destination = " user@server "
        setup.targetHost = "::1"
        XCTAssertEqual(try SSHCommand(setup.validatedCommand()).userArguments, ["-L", "127.0.0.1:8080:[::1]:80"])
        setup.targetHost = "[2001:db8::1]"
        XCTAssertEqual(try TunnelSetup(command: SSHCommand(setup.validatedCommand())).targetHost, "[2001:db8::1]")
        for field in ["0", "65536", "-1", "+22", "abc", "22:80", ""] {
            var bad = setup
            bad.listenPort = field
            XCTAssertThrowsError(try bad.validatedCommand(), field)
            bad = setup
            bad.targetPort = field
            XCTAssertThrowsError(try bad.validatedCommand(), field)
            if !field.isEmpty {
                bad = setup
                bad.sshPort = field
                XCTAssertThrowsError(try bad.validatedCommand(), field)
            }
        }
        for host in ["https://example.com", "localhost:80", "[::1", "[localhost]", "", "a b", "bad\0host"] {
            setup.targetHost = host
            XCTAssertThrowsError(try setup.validatedCommand(), host)
        }
        setup.changeKind(to: .dynamic)
        XCTAssertNoThrow(try setup.validatedCommand(), "SOCKS ignores hidden service fields.")
        setup.listenPort = "5000"
        setup.changeKind(to: .local)
        XCTAssertEqual(setup.listenPort, "5000", "Changing the type preserves a custom port.")
    }

    func testLoginHelpPreservesAuthenticationAndRemovesForwards() throws {
        let command = try SSHCommand("ssh -i '/tmp/key with spaces' -J jump -p2202 -o 'SessionType=none' -o 'BatchMode=yes' -o 'ForkAfterAuthentication=yes' -o 'RemoteCommand=echo hi' -L8080:localhost:80 -o 'RemoteForward=9090 localhost:90' -D1080 alias")
        let login = try SSHCommand.tokenize(command.loginCommand)
        XCTAssertEqual(login.first, "ssh")
        XCTAssertEqual(login.last, "alias")
        XCTAssertTrue(login.contains("/tmp/key with spaces"))
        XCTAssertTrue(login.contains("jump"))
        XCTAssertTrue(login.contains("2202"))
        XCTAssertTrue(login.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(login.contains("BatchMode=no"))
        XCTAssertTrue(login.contains("SessionType=default"))
        XCTAssertTrue(login.contains("ForkAfterAuthentication=no"))
        for text in ["-L", "-R", "-D", "SessionType=none", "BatchMode=yes", "ForkAfterAuthentication=yes", "RemoteCommand=echo hi", "RemoteForward=9090 localhost:90"] {
            XCTAssertFalse(login.contains(text), text)
        }
    }

    func testRenderedCommandShellQuotesUntrustedValues() throws {
        let values = ["ssh", "-i", "/tmp/my key's $(touch nope)", "-L", "[::1]:8080:[::1]:80", "host"]
        let rendered = SSHCommand.render(values)
        XCTAssertEqual(try SSHCommand.tokenize(rendered), values)
        XCTAssertTrue(rendered.contains("'\\''"))
        XCTAssertTrue(rendered.contains("'[::1]:8080:[::1]:80'"))
    }
}
