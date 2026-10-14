import ArgumentParser
import Foundation
import SiriusClient

// Not @main: ArgumentParser exits 64 on a usage error, and proto.ts gives
// bad usage exit 2.
do {
    var command = try Sirius.parseAsRoot()
    try command.run()
} catch let code as ExitCode {
    exit(code.rawValue)
} catch {
    // --help and --version arrive here too, as a clean exit.
    if Sirius.exitCode(for: error) == .success {
        print(Sirius.fullMessage(for: error))
        exit(ExitStatus.result)
    }
    FileHandle.standardError.write(Data((Sirius.fullMessage(for: error) + "\n").utf8))
    exit(ExitStatus.usage)
}
