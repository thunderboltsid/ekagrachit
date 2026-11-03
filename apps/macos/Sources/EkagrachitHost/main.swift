// ekagrachit-host: Chrome Native Messaging host.
//
// Chrome starts this process when the extension calls connectNative() and
// talks to it over stdin/stdout (32-bit native-endian length + JSON). The host
// is a dumb, validating relay to Ekagrachit.app's Unix socket:
//
//   extension <-stdio-> ekagrachit-host <-unix socket-> Ekagrachit.app
//
// - It reconnects to the app every 1.5 s while the app is not running and
//   reports reachability to the extension with `host_status`.
// - It tells the app which browser process launched it (`host_hello`), which
//   the app uses to identify the browser's windows.
// - It exits when Chrome closes stdin (extension disconnected / Chrome quit).
// - Nothing but protocol frames may ever be written to stdout.
import EkagrachitCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let hostVersion = "0.1.1"
signal(SIGPIPE, SIG_IGN)

func log(_ s: String) {
    FileHandle.standardError.write(Data("ekagrachit-host: \(s)\n".utf8))
}

final class Relay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ekagrachit.host")
    private let stdoutLock = NSLock()
    private var conn: FramedConnection?
    private let socketPath = Paths.socketPath
    private let browserPid = getppid()
    private var lastReportedConnected: Bool?

    func writeToChrome(_ payload: Data) {
        guard payload.count <= Framing.maxMessageSize else { return }
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        if !UnixSocket.writeAll(STDOUT_FILENO, Framing.encode(payload)) {
            exit(0) // Chrome went away
        }
    }

    private func report(_ connected: Bool) {
        guard lastReportedConnected != connected else { return }
        lastReportedConnected = connected
        writeToChrome(HostMessages.status(appConnected: connected, hostVersion: hostVersion))
    }

    /// Runs on `queue`.
    func connectLoop() {
        if conn == nil {
            do {
                let fd = try UnixSocket.connect(path: socketPath)
                let c = FramedConnection(fd: fd, ioQueue: DispatchQueue(label: "ekagrachit.host.io"), deliveryQueue: queue)
                c.onFrame = { [weak self] frame in self?.writeToChrome(frame) }
                c.onClose = { [weak self] in
                    guard let self else { return }
                    self.conn = nil
                    self.report(false)
                }
                conn = c
                c.start()
                c.send(HostMessages.hello(browserPid: browserPid, hostVersion: hostVersion))
                report(true)
            } catch {
                report(false)
            }
        }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connectLoop() }
    }

    /// A frame from the extension. Only well-formed JSON objects with a string
    /// `type` are forwarded; the app validates everything again.
    func fromChrome(_ frame: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], obj["type"] is String else {
            log("dropping malformed message from extension")
            return
        }
        queue.async { [weak self] in
            self?.conn?.send(frame) // dropped while the app is unavailable; the extension knows via host_status
        }
    }

    func start() {
        queue.async { self.connectLoop() }
        // Read Chrome's stdin on a dedicated thread (blocking reads).
        let reader = Thread {
            var decoder = FrameDecoder()
            while true {
                guard let chunk = UnixSocket.readChunk(STDIN_FILENO), !chunk.isEmpty else {
                    exit(0) // EOF: Chrome closed the port
                }
                do {
                    for frame in try decoder.feed(chunk) { self.fromChrome(frame) }
                } catch {
                    log("oversized message from extension; exiting")
                    exit(1)
                }
            }
        }
        reader.start()
    }
}

// Chrome passes the caller origin (chrome-extension://<id>/) as the first
// argument; the manifest's allowed_origins already restricts who may launch us.
let relay = Relay()
relay.start()
dispatchMain()
