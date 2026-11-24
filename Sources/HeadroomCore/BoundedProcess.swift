import Foundation

/// Runs a short-lived helper CLI with a hard wall-clock bound. Stdout is
/// drained by a dispatch read source (never a blocking read to EOF), so a
/// child that ignores SIGTERM, or a grandchild that keeps the pipe open,
/// can't hold the caller past `timeout + killGrace`.
enum BoundedProcess {
    enum Outcome: Equatable {
        case exited(status: Int32, output: Data)
        case launchFailed
        case timedOut
        case outputTooLarge
    }

    struct Limits: Sendable {
        var timeout: TimeInterval = 20
        /// Time between SIGTERM and SIGKILL.
        var killGrace: TimeInterval = 2
        var outputLimit = 1 << 20
    }

    /// Blocking; call from a utility queue, not the cooperative pool.
    static func run(_ executable: URL, arguments: [String], limits: Limits) -> Outcome {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let reader = Reader(handle: pipe.fileHandleForReading, limit: limits.outputLimit)
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            reader.cancel()
            return .launchFailed
        }

        let deadline = DispatchTime.now() + limits.timeout
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + limits.killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            reader.cancel()
            return reader.tooLarge ? .outputTooLarge : .timedOut
        }
        // The child is gone, so whatever it wrote is already in the pipe buffer;
        // a brief wait for EOF covers the drain without trusting grandchildren.
        _ = reader.finished.wait(timeout: .now() + 1)
        reader.cancel()
        if reader.tooLarge { return .outputTooLarge }
        return .exited(status: process.terminationStatus, output: reader.data)
    }

    private final class Reader: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let queue = DispatchQueue(label: "headroom.bounded-process.reader", qos: .utility)
        private let source: DispatchSourceRead
        private let fd: Int32
        private let limit: Int
        // Queue-confined.
        private var buffer = Data()
        private var overflow = false
        private var done = false

        init(handle: FileHandle, limit: Int) {
            fd = handle.fileDescriptor
            self.limit = limit
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            // The fd is closed only here, after any in-flight read has returned.
            source.setCancelHandler { try? handle.close() }
            source.resume()
        }

        var data: Data { queue.sync { buffer } }
        var tooLarge: Bool { queue.sync { overflow } }

        /// Stops reading and closes our end of the pipe; idempotent.
        func cancel() {
            queue.sync { finish() }
        }

        private func drain() {
            guard !done else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                if buffer.count > limit { overflow = true; finish() }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                finish()
            }
        }

        private func finish() {
            guard !done else { return }
            done = true
            finished.signal()
            source.cancel()
        }
    }
}
