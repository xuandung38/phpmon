//
//  RealShell.swift
//  PHP Monitor
//
//  Created by Nico Verbruggen on 21/09/2022.
//  Copyright © 2023 Nico Verbruggen. All rights reserved.
//

import Foundation

extension Process: @unchecked Sendable {}
extension Timer: @unchecked Sendable {}

class RealShell: ShellProtocol {
    /**
     The launch path of the terminal in question that is used.
     On macOS, we use /bin/sh since it's pretty fast.
     */
    private(set) var launchPath: String = "/bin/sh"

    /**
     For some commands, we need to know what's in the user's PATH.
     The entire PATH is retrieved here, so we can set the PATH in our own terminal as necessary.
     */
    private(set) var PATH: String = { return RealShell.getPath() }()

    /**
     Exports are additional environment variables set by the user via the custom configuration.
     These are populated when the configuration file is being loaded.
     */
    var exports: String = ""

    /** Retrieves the user's PATH by opening an interactive shell and echoing $PATH. */
    private static func getPath() -> String {
        let task = Process()
        task.launchPath = "/bin/zsh"

        // We need an interactive shell so the user's PATH is loaded in correctly
        task.arguments = ["--login", "-ilc", "echo $PATH"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()

        return String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: String.Encoding.utf8
        ) ?? ""
    }

    /**
     Create a process that will run the required shell with the appropriate arguments.
     This process still needs to be started, or one can attach output handlers.
     */
    private func getShellProcess(for command: String) -> Process {
        var completeCommand = ""

        // Basic export (PATH)
        completeCommand += "export PATH=\(Paths.binPath):$PATH && "

        // Put additional exports (as defined by the user) in between
        if !self.exports.isEmpty {
            completeCommand += "\(self.exports) && "
        }

        completeCommand += command

        let task = Process()
        task.launchPath = self.launchPath
        task.arguments = ["--noprofile", "-norc", "--login", "-c", completeCommand]

        return task
    }

    // MARK: - Public API

    /**
     Set custom environment variables.
     These will be exported when a command is executed.
     */
    public func setCustomEnvironmentVariables(_ variables: [String: String]) {
        self.exports = variables.map { (key, value) in
            return "export \(key)=\(value)"
        }.joined(separator: "&&")
    }

    // MARK: - Shellable Protocol

    func pipe(_ command: String) async -> ShellOutput {
        let task = getShellProcess(for: command)

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Seriously slow down how long it takes for the shell to return output
        // (in order to debug or identify async issues)
        if ProcessInfo.processInfo.environment["SLOW_SHELL_MODE"] != nil {
            Log.info("[SLOW SHELL] \(command)")
            await delay(seconds: 3.0)
        }

        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.launch()
        task.waitUntilExit()

        let stdOut = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )!

        let stdErr = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )!

        if Log.shared.verbosity == .cli {
            var args = task.arguments ?? []
            let last = "\"" + (args.popLast() ?? "") + "\""
            var log = """

            <~~~~~~~~~~~~~~~~~~~~~~~
            $ \(([self.launchPath] + args + [last]).joined(separator: " "))

            [OUT]:
            \(stdOut)
            """

            if !stdErr.isEmpty {
                log.append("""
                [ERR]:
                \(stdErr)
                """)
            }

            log.append("""
            ~~~~~~~~~~~~~~~~~~~~~~~~>

            """)

            Log.info(log)
        }

        return .out(stdOut, stdErr)
    }

    func quiet(_ command: String) async {
        _ = await self.pipe(command)
    }

    func attach(
        _ command: String,
        didReceiveOutput: @escaping (String, ShellStream) -> Void,
        withTimeout timeout: TimeInterval = 5.0
    ) async throws -> (Process, ShellOutput) {
        let process = getShellProcess(for: command)

        let output = ShellOutput.empty()

        process.listen { incoming in
            output.out += incoming; didReceiveOutput(incoming, .stdOut)
        } didReceiveStandardErrorData: { incoming in
            output.err += incoming; didReceiveOutput(incoming, .stdErr)
        }

        return try await withCheckedThrowingContinuation({ continuation in
            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                // Only terminate if the process is still running
                if process.isRunning {
                    process.terminationHandler = nil
                    process.terminate()
                    return continuation.resume(throwing: ShellError.timedOut)
                }
            }

            process.terminationHandler = { [timer, output] process in
                timer.invalidate()

                process.haltListening()

                if !output.err.isEmpty {
                    return continuation.resume(returning: (process, .err(output.err)))
                }

                return continuation.resume(returning: (process, .out(output.out)))
            }

            process.launch()
            process.waitUntilExit()
        })
    }
}
