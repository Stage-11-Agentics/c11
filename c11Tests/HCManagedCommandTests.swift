import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCManagedCommandTests: XCTestCase {
    let environment = ["HC_SESSION": "c11", "HC_SOCKET": "/owned.sock", "SHELL": "/bin/zsh", "TERM": "xterm-ghostty",
                       "XDG_CONFIG_HOME": "/tenant/config", "PRIVATE_TOKEN": "do-not-copy"]

    func testRunPreservesArgumentBoundariesAndSelectedEnvironment() throws {
        let request = try HCManagedCommandParser.parse(["run", "--bg", "--cwd", "/a b", "--env", "EXPLICIT=a=b", "--label", "job=42", "--", "sh", "-c", "echo $HOME"],
                                                        environment: environment, cwd: "/start")
        XCTAssertEqual(request.verb, .run)
        XCTAssertEqual(request.argv, ["sh", "-c", "echo $HOME"])
        XCTAssertEqual(request.cwd, "/a b")
        XCTAssertEqual(request.environment["EXPLICIT"], "a=b")
        XCTAssertEqual(request.environment["XDG_CONFIG_HOME"], "/tenant/config")
        XCTAssertNil(request.environment["PRIVATE_TOKEN"])
        XCTAssertNil(request.environment["HC_SOCKET"])
        XCTAssertEqual(request.labels, ["job": "42"])
    }

    func testRuntimeMutationAndHCEnvironmentOverridesAreRefused() {
        for args in [["update"], ["server", "start"], ["server", "stop"], ["run", "--env", "HC_SOCKET=/foreign", "sh"], ["run", "--keep", "sh"]] {
            XCTAssertThrowsError(try HCManagedCommandParser.parse(args, environment: environment, cwd: "/"))
        }
    }

    func testUnsupportedFlagsAndMissingTupleDoNotBecomeDifferentCommands() {
        for args in [["ls", "--on", "other"], ["get"], ["get", "t1", "--unknown"], ["server", "restart", "extra"]] {
            XCTAssertThrowsError(try HCManagedCommandParser.parse(args, environment: environment, cwd: "/"))
        }
        XCTAssertThrowsError(try HCManagedCommandParser.parse(["ls"], environment: [:], cwd: "/"))
    }

    /// C11H-42: read-only machine inventory only. Adding or removing a machine
    /// stays with scripts/c11-atlas-link.sh.
    func testMachineLsIsReadOnlyAndMachineChangesAreRefused() throws {
        for spelling in ["ls", "list"] {
            let request = try HCManagedCommandParser.parse(["machine", spelling], environment: environment, cwd: "/")
            XCTAssertEqual(request.verb, .machineList)
            XCTAssertEqual(request.session, "c11")
        }
        XCTAssertEqual(try HCManagedCommandParser.parse(["machine", "ls", "--json"], environment: environment, cwd: "/").verb, .machineList)
        for args in [["machine", "add", "studio", "ssh://studio"], ["machine", "remove", "studio"], ["machine", "rm", "studio"],
                     ["machine", "link"], ["machine", "ls", "studio"], ["machine", "ls", "--on", "studio"]] {
            XCTAssertThrowsError(try HCManagedCommandParser.parse(args, environment: environment, cwd: "/"), "\(args)")
        }
        XCTAssertThrowsError(try HCManagedCommandParser.parse(["machine"], environment: environment, cwd: "/"))
        XCTAssertThrowsError(try HCManagedCommandParser.parse(["machine", "ls"], environment: [:], cwd: "/"))
    }

    func testEmptyRunUsesCallerShellNotSharedConfig() throws {
        let request = try HCManagedCommandParser.parse(["run", "--bg"], environment: environment, cwd: "/here")
        XCTAssertEqual(request.argv, ["/bin/zsh"])
    }
}
