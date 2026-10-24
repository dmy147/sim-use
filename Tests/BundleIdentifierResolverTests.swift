// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import Foundation
import SimUseCore
import Testing

@Suite("BundleIdentifierResolver — launchctl parsing")
struct BundleIdentifierResolverTests {

    @Test("Extracts bundle id from UIKitApplication label")
    func extractsBundleId() {
        let bundleId = BundleIdentifierResolver.bundleId(fromLabel: "UIKitApplication:com.example.MyApp[1234][b-xyz]")
        #expect(bundleId == "com.example.MyApp")
    }

    @Test("Returns nil for non-UIKitApplication labels")
    func ignoresDaemonLabel() {
        #expect(BundleIdentifierResolver.bundleId(fromLabel: "com.apple.mediaserverd") == nil)
        #expect(BundleIdentifierResolver.bundleId(fromLabel: "com.apple.SpringBoard") == nil)
    }

    @Test("Handles UIKitApplication label without bracket suffix")
    func handlesNoBrackets() {
        let bundleId = BundleIdentifierResolver.bundleId(fromLabel: "UIKitApplication:com.example.MyApp")
        #expect(bundleId == "com.example.MyApp")
    }

    @Test("Parses launchctl list output and finds pid")
    func parsesMatchingPid() {
        let output = """
        PID	Status	Label
        -	0	com.apple.something
        12345	0	UIKitApplication:com.example.app[5678][a-1234]
        67890	-	com.apple.other.service
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 12345) == "com.example.app")
    }

    @Test("Returns nil when pid not present")
    func returnsNilForMissingPid() {
        let output = """
        PID	Status	Label
        12345	0	UIKitApplication:com.example.app[5678][a-1234]
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 999) == nil)
    }

    @Test("Skips header and empty lines")
    func skipsHeader() {
        let output = """
        PID Status Label

        100 0 UIKitApplication:com.bundle.id[xx]
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 100) == "com.bundle.id")
    }

    @Test("Returns nil for system-daemon-only output")
    func systemOnlyReturnsNil() {
        let output = """
        100	0	com.apple.SpringBoard
        200	0	com.apple.mediaserverd
        """
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 100) == nil)
    }

    // MARK: - appsByPid (full hosted-app map for liveness tracking)

    @Test("appsByPid maps every running UIKitApplication row to its bundle id")
    func appsByPidMapsRunningApps() {
        let output = """
        PID	Status	Label
        -	0	UIKitApplication:com.example.notrunning[0000][a-0]
        100	0	UIKitApplication:com.example.app[5678][a-1234]
        200	0	UIKitApplication:com.example.other[9999][b-1]
        300	0	com.apple.mediaserverd
        400	0	com.apple.SpringBoard
        """
        let map = BundleIdentifierResolver.appsByPid(launchctlOutput: output)
        #expect(map == [100: "com.example.app", 200: "com.example.other"])
    }

    @Test("appsByPid is empty for daemon-only / blank output")
    func appsByPidEmptyForDaemons() {
        #expect(BundleIdentifierResolver.appsByPid(launchctlOutput: "100\t0\tcom.apple.mediaserverd").isEmpty)
        #expect(BundleIdentifierResolver.appsByPid(launchctlOutput: "").isEmpty)
    }

    // MARK: - Foreground resolution (recognises SpringBoard's daemon label)

    @Test("foregroundBundleId maps the SpringBoard daemon label to its canonical bundle id")
    func foregroundResolvesSpringBoard() {
        // SpringBoard's launchctl label is the plain daemon form
        // `com.apple.SpringBoard`, not `UIKitApplication:` — but it is
        // the foreground after a crash, so the header must name it.
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "com.apple.SpringBoard") == "com.apple.springboard")
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "UIKitApplication:com.x[1]") == "com.x")
        #expect(BundleIdentifierResolver.foregroundBundleId(fromLabel: "com.apple.mediaserverd") == nil)
    }

    @Test("parseForeground resolves SpringBoard by pid where parse (apps-only) would not")
    func parseForegroundFindsSpringBoard() {
        let output = """
        PID	Status	Label
        51146	0	com.apple.SpringBoard
        51950	0	UIKitApplication:com.apple.mobilesafari[1][a]
        """
        #expect(BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: 51146) == "com.apple.springboard")
        #expect(BundleIdentifierResolver.parse(launchctlOutput: output, pid: 51146) == nil)
        #expect(BundleIdentifierResolver.parseForeground(launchctlOutput: output, pid: 51950) == "com.apple.mobilesafari")
    }
}
@Suite("BundleIdentifierResolver — child process hygiene")
struct BundleIdentifierResolverProcessTests {

    // The daemon leaked both pipes of every launchctl read (2 fds per
    // `ui` call, 36 -> 636 after 300 reads), until spawning failed and every process-list read broke.
    // Counting the process's descriptors is not reliable while other suites run in parallel, so the
    // test records each read end's descriptor and pipe identity: after the run that descriptor is
    // closed or, if a parallel suite reused the number, names another file.
    @Test("Every run closes the read ends of its pipes")
    func runsCloseTheirPipes() throws {
        func identity(_ fd: Int32) -> (dev: dev_t, ino: ino_t)? {
            var info = stat()
            return fstat(fd, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        }
        var readers: [(fd: Int32, dev: dev_t, ino: ino_t)] = []
        let echo = URL(fileURLWithPath: "/bin/echo")
        let output = try BundleIdentifierResolver.runCapturing(executable: echo, arguments: ["hello"], timeout: 5) {
            let pipe = Pipe()
            let fd = pipe.fileHandleForReading.fileDescriptor
            if let id = identity(fd) { readers.append((fd, id.dev, id.ino)) }
            return pipe
        }
        #expect(output == "hello\n")
        #expect(readers.count == 2)
        for reader in readers {
            let now = identity(reader.fd)
            #expect(now == nil || now!.dev != reader.dev || now!.ino != reader.ino, "read end \(reader.fd) is still open")
        }
    }
}
