// Every macOS executable depends on NMCore, including the standalone MCP server.
// Keep this check in compiled source so direct SwiftPM builds enforce the policy.
#if !os(macOS) || !arch(arm64)
#error("NETworkManager requires Apple Silicon (arm64) and macOS 14 or later. Intel builds are not supported.")
#endif
