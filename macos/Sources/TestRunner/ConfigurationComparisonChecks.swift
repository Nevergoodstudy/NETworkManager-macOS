import Foundation
@testable import NMCore

enum ConfigurationComparisonChecks {
    static func capture() async throws {
        let ios = "Building configuration...\nCurrent configuration : 128 bytes\n!\ninterface Ethernet1\n shutdown\nusername operator secret fixture-secret\nend\n"
        let junos = "set system host-name fixture\nset interfaces ge-0/0/0 mtu 1500\n"
        let before = try ConfigurationComparison.capture(CommandResult(status: 0, stdout: ios, stderr: ""),
                                                        format: .ciscoIOS, target: "ios.fixture")
        let after = try ConfigurationComparison.capture(CommandResult(status: 0, stdout: ios.replacingOccurrences(of: " shutdown", with: " no shutdown"), stderr: ""),
                                                       format: .ciscoIOS, target: "ios.fixture")
        let result = try await ConfigurationComparison.compare(before: before, after: after, format: .ciscoIOS)
        try check(before.title.hasPrefix("ios.fixture") && result.beforeSHA256 != result.afterSHA256 &&
                  result.changes.map(\.text).sorted() == ["interface Ethernet1 / no shutdown", "interface Ethernet1 / shutdown"],
                  "Completed capture feeds the normal SHA-256 and redacted comparison")
        _ = try ConfigurationComparison.capture(CommandResult(status: 0, stdout: junos, stderr: ""),
                                                format: .junosSet, target: "junos.fixture")
        let incomplete: [(ConfigurationComparison.Format, CommandResult)] = [
            (.ciscoIOS, CommandResult(status: 0, stdout: ios.replacingOccurrences(of: "end\n", with: ""), stderr: "")),
            (.ciscoIOS, CommandResult(status: 0, stdout: ios + "--More--\n", stderr: "")),
            (.junosSet, CommandResult(status: 0, stdout: junos + "ACCESS-DENIED\n", stderr: "")),
            (.junosSet, CommandResult(status: 0, stdout: String(junos.dropLast()), stderr: "")),
            (.junosSet, CommandResult(status: 255, stdout: junos, stderr: "Connection closed")),
        ]
        for (format, command) in incomplete {
            do {
                _ = try ConfigurationComparison.capture(command, format: format, target: "fixture")
                throw CheckFailure(description: "A partial configuration was accepted")
            } catch ConfigurationComparison.CaptureFailure.incomplete {}
        }
        do {
            _ = try ConfigurationComparison.capture(CommandResult(status: 0, stdout: ios, stderr: "", stdoutTruncated: true),
                                                    format: .ciscoIOS, target: "fixture")
            throw CheckFailure(description: "Truncated command output was accepted")
        } catch ConfigurationComparison.Failure.limit {}
    }

    static func run() throws {
        let before = Data("""
        interface Ethernet1
         ip address 192.0.2.1 255.255.255.0
        interface Ethernet2
         shutdown
        banner motd ^C
        ip address cafe 255.255.255.0
        ^C
        username operator secret fixture-old
        """.utf8)
        let after = Data("""
        interface Ethernet1
        interface Ethernet2
         ip address 192.0.2.1 255.255.255.0
         no shutdown
        banner motd ^C
        ip address dead 255.255.255.0
        ^C
        username operator secret fixture-new
        """.utf8)
        let ios = try ConfigurationComparison.compare(before: before, after: after, format: .ciscoIOS)
        try check(ios.beforeSHA256.count == 64 && ios.afterSHA256.count == 64 && ios.beforeSHA256 != ios.afterSHA256 &&
                  ios.omittedLinesChanged && ios.changes.count == 4,
                  "IOS comparison must track hidden differences and moved addresses")
        try check(ios.changes.contains {
            $0.kind == .removed && $0.line == 2 && $0.text == "interface Ethernet1 / ip address 192.0.2.1 255.255.255.0"
        } && ios.changes.contains {
            $0.kind == .added && $0.line == 3 && $0.text == "interface Ethernet2 / ip address 192.0.2.1 255.255.255.0"
        }, "IOS comparison must retain original line numbers and distinguish interfaces")
        try check(ios.changes.allSatisfy { !$0.text.contains("fixture") && !$0.text.contains("dead") && !$0.text.contains("cafe") },
                  "IOS comparison exposed a secret or banner payload")

        for command in ["BANNER motd", "aaa authentication banner", "aaa authentication fail-message"] {
            let before = Data("\(command) ^C\nmtu 1400\n^C\ninterface Ethernet1\n shutdown\n".utf8)
            let after = Data("\(command) ^C\nmtu 1500\n^C\ninterface Ethernet1\n no shutdown\n".utf8)
            let report = try ConfigurationComparison.compare(before: before, after: after, format: .ciscoIOS)
            try check(report.omittedLinesChanged && report.changes.map(\.text).sorted() == [
                "interface Ethernet1 / no shutdown", "interface Ethernet1 / shutdown"
            ], "IOS multiline messages must hide their contents and resume comparison at the closing delimiter")
        }

        for command in ["menu Access1 title", "menu Access1 prompt", " vacant-message"] {
            let before = Data("\(command) /\ninterface HiddenBefore\n/\ninterface Ethernet1\n shutdown\n".utf8)
            let after = Data("\(command) /\ninterface HiddenAfter\n/\ninterface Ethernet1\n no shutdown\n".utf8)
            let report = try ConfigurationComparison.compare(before: before, after: after, format: .ciscoIOS)
            try check(report.omittedLinesChanged && report.changes.map(\.text).sorted() == [
                "interface Ethernet1 / no shutdown", "interface Ethernet1 / shutdown"
            ], "IOS \(command) must hide delimited text and retain changes after the closing delimiter")
        }

        let defaultVacantMessage = try ConfigurationComparison.compare(
            before: Data(" vacant-message\ninterface Ethernet1\n shutdown\n".utf8),
            after: Data(" vacant-message\ninterface Ethernet1\n no shutdown\n".utf8), format: .ciscoIOS)
        try check(!defaultVacantMessage.omittedLinesChanged && defaultVacantMessage.changes.count == 2,
                  "An IOS vacant-message without arguments restores the default and does not consume later commands")

        let inlineMessage = try ConfigurationComparison.compare(
            before: Data("aaa authentication banner *Before*\ninterface Ethernet1\n shutdown\n".utf8),
            after: Data("aaa authentication banner *After*\ninterface Ethernet1\n no shutdown\n".utf8), format: .ciscoIOS)
        try check(inlineMessage.omittedLinesChanged && inlineMessage.changes.count == 2,
                  "An inline AAA banner must not suppress subsequent configuration commands")

        let hiddenBefore = Data("interface Ethernet1\n description fixture-private\ninterface Ethernet2\n".utf8)
        let hiddenAfter = Data("interface Ethernet1\ninterface Ethernet2\n description fixture-private\n".utf8)
        let hiddenMove = try ConfigurationComparison.compare(before: hiddenBefore, after: hiddenAfter, format: .ciscoIOS)
        try check(hiddenMove.omittedLinesChanged && hiddenMove.changes.isEmpty,
                  "Moving an omitted IOS command between interfaces must be reported without showing the command")
        let visibleAfter = Data("interface Ethernet1\n shutdown\n description fixture-private\ninterface Ethernet2\n".utf8)
        let visibleInsert = try ConfigurationComparison.compare(before: hiddenBefore, after: visibleAfter, format: .ciscoIOS)
        try check(!visibleInsert.omittedLinesChanged && visibleInsert.changes.count == 1,
                  "A displayed command shifting the line number of an omitted command must not report a hidden change")

        let junosBefore = Data("set system root-authentication encrypted-password fixture-secret\nset interfaces ge-0/0/0 unit 0 family inet6 address 2001:db8::1/64\n".utf8)
        let junosAfter = Data("set system root-authentication encrypted-password fixture-secret\nset interfaces ge-0/0/0 unit 0 family inet6 address 2001:db8::2/64\n".utf8)
        let junos = try ConfigurationComparison.compare(before: junosBefore, after: junosAfter, format: .junosSet)
        try check(!junos.omittedLinesChanged && junos.changes.count == 2 && junos.changes.allSatisfy {
            $0.line == 2 && $0.text.hasPrefix("set interfaces ge-0/0/0 unit 0 family inet6 address ")
        }, "Junos comparison shows IPv6 changes and leaves encrypted-password lines outside the result")

        do {
            _ = try ConfigurationComparison.compare(before: Data([0xff]), after: junosAfter, format: .junosSet)
            throw CheckFailure(description: "Non-UTF-8 data passed configuration comparison")
        } catch ConfigurationComparison.Failure.invalidText {}
    }
}
