import Foundation

/// 运行外部命令：分别收集标准输出和标准错误，限制输出大小，超时则结束进程。
public enum ProcessRunner {
    public struct Output: Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: Data
        public var stderr: Data
    }

    public enum Failure: Error, Sendable, Equatable {
        /// 命令无法启动，参数是系统给出的原因。
        case launchFailed(String)
        case timedOut
        /// 标准输出超过 `outputLimit`。
        case outputTooLarge
    }

    /// - Parameters:
    ///   - command: 第一项以 `/` 开头时直接执行，否则通过 `/usr/bin/env` 在 `environment` 的 PATH 中查找。
    ///   - directory: 工作目录。标准输入为空。
    ///   - environment: 进程的完整环境变量。
    ///   - outputLimit: 标准输出和标准错误各自的字节上限；标准输出超出时按失败处理，标准错误超出部分丢弃。
    public static func run(
        _ command: [String], in directory: URL, environment: [String: String],
        timeout: TimeInterval, outputLimit: Int
    ) async throws -> Output {
        precondition(!command.isEmpty)
        return try await withCheckedThrowingContinuation { continuation in
            let run = Run(continuation)
            let process = run.process
            if command[0].hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: command[0])
                process.arguments = Array(command.dropFirst())
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = command
            }
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                run.finish(.failure(.launchFailed(error.localizedDescription)))
                return
            }

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                if !run.read(stdout.fileHandleForReading, into: \.stdout, limit: outputLimit) {
                    run.finish(.failure(.outputTooLarge))
                    run.kill()
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                _ = run.read(stderr.fileHandleForReading, into: \.stderr, limit: outputLimit)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }
            group.notify(queue: .global()) {
                run.finish(.success(run.output(exitCode: process.terminationStatus)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // 超时后立即返回，不等子进程关闭管道
                if run.finish(.failure(.timedOut)) { run.kill() }
            }
        }
    }

    /// 一次运行的共享状态；跨线程访问都经过 `lock`。
    private final class Run: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        private var buffers = Buffers()

        struct Buffers {
            var stdout = Data()
            var stderr = Data()
        }

        init(_ continuation: CheckedContinuation<Output, Error>) {
            self.continuation = continuation
        }

        /// 只有第一次调用生效；返回这次调用是否生效。
        @discardableResult
        func finish(_ result: Result<Output, Failure>) -> Bool {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            guard let continuation else { return false }
            continuation.resume(with: result.mapError { $0 as Error })
            return true
        }

        /// 读到 EOF；超过上限时返回 false。
        func read(_ handle: FileHandle, into buffer: WritableKeyPath<Buffers, Data>, limit: Int) -> Bool {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return true }
                let exceeded = lock.withLock {
                    let room = max(0, limit - buffers[keyPath: buffer].count)
                    buffers[keyPath: buffer].append(chunk.prefix(room))
                    return chunk.count > room
                }
                if exceeded { return false }
            }
        }

        func output(exitCode: Int32) -> Output {
            lock.withLock { Output(exitCode: exitCode, stdout: buffers.stdout, stderr: buffers.stderr) }
        }

        /// 结束进程（也尝试结束它所在的进程组），2 秒后仍未退出就强制结束。
        func kill() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            Darwin.kill(-pid, SIGTERM)
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
