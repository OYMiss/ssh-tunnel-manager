import XCTest
@testable import SSHTunnelCore

final class CommandTests: XCTestCase {
    func testAttachedOptionsQuotesAndIPv6() throws {
        let command = try SSHCommand("ssh -NT -p2222 -i '~/.ssh/key with spaces' -L '[::1]:8080:[::1]:80' -D1080 user@server")
        XCTAssertEqual(command.destination, "user@server")
        XCTAssertEqual(command.forwards.map(\.port), [8080, 1080])
        XCTAssertTrue(command.userArguments.contains(NSHomeDirectory() + "/.ssh/key with spaces"))
        XCTAssertEqual(command.arguments.prefix(3), ["-N", "-T", "-v"])
    }
    func testRejectsUnmanagedCommandsAndBadPorts() {
        for command in ["ssh -fND 1080 host", "ssh -D1080 host &", "ssh -D1080 host ls", "ssh -D0 host", "ssh -D65536 host", "ssh host", "ssh -D1080 'host", "ssh -D1080 -L1080:localhost:80 host", "ssh -S socket -O exit host", "ssh -o = -D1080 host", "ssh -D1080 host\0suffix"] {
            XCTAssertThrowsError(try SSHCommand(command), command)
        }
    }
    func testRemoteForwardAndConfigStyleForwards() throws {
        let command = try SSHCommand("ssh -R 8080:localhost:80 -o 'LocalForward=127.0.0.1:9090 localhost:90' -o 'DynamicForward 1080' alias")
        XCTAssertEqual(command.remoteForwardCount, 1)
        XCTAssertEqual(command.forwards.map(\.port), [8080, 9090, 1080])
    }
    func testManagedOptionsPrecedeUserOptions() throws {
        let command = try SSHCommand("ssh -o ForkAfterAuthentication=yes -o ExitOnForwardFailure=no -D1080 alias")
        let args = command.arguments
        XCTAssertLessThan(args.firstIndex(of: "ForkAfterAuthentication=no")!, args.firstIndex(of: "ForkAfterAuthentication=yes")!)
        XCTAssertLessThan(args.firstIndex(of: "ExitOnForwardFailure=yes")!, args.firstIndex(of: "ExitOnForwardFailure=no")!)
    }
}
