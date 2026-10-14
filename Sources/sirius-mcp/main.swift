import Darwin
import Foundation

// MCP over stdio: initialize, tools/list, tools/call. stdout carries only
// protocol lines; anything else goes to stderr.

// A host that closes our stdout must end us quietly, not by SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let server = MCPServer(environment: ProcessInfo.processInfo.environment)

// Writes one line in full; false when stdout is gone.
func writeLine(_ line: String) -> Bool {
    var bytes = Array(line.utf8)
    bytes.append(0x0A)
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

// Calls run one at a time, in order; each waits at most SIRIUS_TIMEOUT.
while let line = readLine(strippingNewline: true) {
    if line.allSatisfy(\.isWhitespace) { continue }
    guard let response = server.handle(line) else { continue }
    if !writeLine(response) {
        FileHandle.standardError.write(Data("sirius-mcp: stdout closed\n".utf8))
        exit(0)
    }
}
