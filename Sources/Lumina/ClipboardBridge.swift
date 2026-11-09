import AppKit
@preconcurrency import Virtualization

final class ClipboardBridge: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    static let port: UInt32 = 1025
    private static let maxBytes = 8 << 20
    private static let skippedTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    private let queue = DispatchQueue(label: "com.lumina.clipboard")
    private let listener = VZVirtioSocketListener()
    private var connection: VZVirtioSocketConnection?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var last: String?
    private var changeCount = 0

    init(socket: VZVirtioSocketDevice) {
        super.init()
        listener.delegate = self
        socket.setSocketListener(listener, forPort: Self.port)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            detach()
        }
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let box = UncheckedSendable(connection)
        queue.async { self.attach(box.value) }
        return true
    }

    private func attach(_ newConnection: VZVirtioSocketConnection) {
        detach()
        connection = newConnection
        disableSigpipe(fd: newConnection.fileDescriptor)
        let source = DispatchSource.makeReadSource(fileDescriptor: newConnection.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
        reader = source
        changeCount = -1
        poll()
    }

    private func detach() {
        reader?.cancel()
        reader = nil
        connection?.close()
        connection = nil
        buffer.removeAll()
        last = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard connection != nil, pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.skippedTypes.contains),
              let text = pasteboard.string(forType: .string), text != last,
              text.utf8.count <= Self.maxBytes,
              let fd = connection?.fileDescriptor else { return }
        last = text
        if !writeAll(fd: fd, data: Data(text.utf8).base64EncodedData() + [0x0A]) { detach() }
    }

    private func receive() {
        guard let fd = connection?.fileDescriptor else { return }
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { return detach() }
        buffer.append(contentsOf: chunk[..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let data = Data(base64Encoded: line),
                  let text = String(data: data, encoding: .utf8), text != last else { continue }
            last = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            changeCount = pasteboard.changeCount
        }
        if buffer.count > Self.maxBytes * 2 { buffer.removeAll() }
    }
}
