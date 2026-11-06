---
sidebar_position: 1
description: "Build and package the native NETworkManager macOS edition."
keywords: [NETworkManager, macOS, SwiftUI, AppKit, network tools, DMG]
---

# macOS edition

NETworkManager includes a native macOS edition in the repository's macos/
directory. It targets macOS 14 or later and uses SwiftUI for the interface,
AppKit for application commands and system handoffs, and native BSD sockets for
network diagnostics.

## Build

From the repository root:

    swift build --package-path macos -c release
    swift run --package-path macos NETworkManagerMac
    swift run --package-path macos NMTest

NMCheck and NMTest are command-line smoke checks. They avoid XCTest so the
package can also be validated on a host with the standalone macOS Command Line
Tools.

## Package

The bundle script creates a self-contained NETworkManager.app and can create
a compressed disk image:

    ./macos/Scripts/build-app.sh
    CREATE_DMG=1 ./macos/Scripts/build-app.sh

Use ARCHITECTURE=arm64 or ARCHITECTURE=x86_64 for a specific architecture, or
ARCHITECTURE=universal for one arm64+x86_64 bundle. Set CODESIGN_IDENTITY to a
Developer ID Application identity before creating a release artifact.
Local builds receive an ad-hoc signature; notarization requires the release
owner's Apple Developer credentials and is intentionally kept outside the
source tree.

The app also accepts the Windows startup selector for scripts and launchers:

    open NETworkManager.app --args --application:PingMonitor
    open NETworkManager.app --args --application=SNMP
    open NETworkManager.app --args --reset-settings
    open NETworkManager.app --args --help

The accepted names map to the macOS sidebar tools, with `ARPTable` mapped to
the Neighbor Table and Windows embedded clients mapped to their macOS handoff.

## Available tools

The macOS edition currently includes the dashboard, network interface view, IP
and TCP port scanners, ping monitor, DNS/WHOIS/SNTP/SNMP lookups, IP
geolocation, subnet and bit calculators, traceroute, WiFi summary, structured
connections/listeners/neighbors, firewall status, hosts file editor,
SSH/Telnet terminal handoff, Web Console browser handoff, AWS Session Manager
terminal handoff, RDP/VNC URL handoff, profiles, import/export, theming,
language selection, and launch-at-login settings.

RDP and VNC require a compatible client installed on the Mac. Hosts file
saving requests administrator authorization. Profile data is stored in
~/Library/Application Support/NETworkManager/; Windows JSON/XML exports are
converted on import, while encrypted macOS exports use an authenticated AES-GCM
`NME1` container with a password-derived key and are not byte-for-byte
compatible with the Windows encrypted container.

The ICMP path uses an unprivileged native datagram socket first. When the
current macOS configuration does not expose a matching reply, the app falls
back to the system `/sbin/ping` executable with an argument array and keeps the
same result model for the IP Scanner and Ping Monitor.

The complete per-tool status, system replacements, optional dependencies and
platform limits are documented in the repository's
[`macos/PORTING_STATUS.md`](https://github.com/BornToBeRoot/NETworkManager/blob/main/macos/PORTING_STATUS.md).
The macOS edition uses native SNMP v1/v2c, structured socket and neighbor
inventories, and explicit IP geolocation lookup. Windows-specific features
retain their Windows implementation in the existing application; features
without a public macOS equivalent are presented as system replacements or
clearly marked partial functionality.
