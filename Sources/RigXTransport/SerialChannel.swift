import Darwin
import Dispatch
import Foundation

/// A real serial port.
///
/// Whatever sits between the Mac and the analyzer — a USB-UART bridge wired to the
/// board's UART pins, an Arduino running RigExpert's repeater sketch, or a Bluetooth
/// SPP link — the Mac side is the same: a `/dev/cu.*` device at 38400 baud.
public actor SerialChannel: ByteChannel {
    private let path: String
    private let baudRate: Int32
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    private static let readQueue = DispatchQueue(label: "com.antscope.serial.read")

    public init(path: String, baudRate: Int32 = AnalyzerSerialSettings.defaultBaudRate) {
        self.path = path
        self.baudRate = baudRate
    }

    public var isOpen: Bool { descriptor >= 0 }

    /// Opens the port and puts it in raw mode.
    public func open() throws {
        guard descriptor < 0 else { return }

        // O_NONBLOCK also stops open() itself from blocking on carrier detect, which a
        // USB-UART bridge may never assert.
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ChannelError.cannotOpen(path: path, errno: errno) }

        // Refuse to share the port with another process; two readers means both get
        // half the bytes.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ChannelError.cannotOpen(path: path, errno: code)
        }

        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ChannelError.cannotConfigure(path: path, errno: code)
        }

        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        cfsetispeed(&settings, speed_t(baudRate))
        cfsetospeed(&settings, speed_t(baudRate))

        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ChannelError.cannotConfigure(path: path, errno: code)
        }
        tcflush(fd, TCIOFLUSH)

        descriptor = fd
    }

    public func received() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.startReading()
        }
    }

    public func send(_ data: Data) throws {
        guard descriptor >= 0 else { throw ChannelError.closed }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR {
                    continue
                } else {
                    throw ChannelError.writeFailed(errno: errno)
                }
            }
        }
    }

    public func close() {
        source?.cancel()
        source = nil
        continuation?.finish()
        continuation = nil
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func startReading() {
        guard descriptor >= 0, source == nil else { return }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: Self.readQueue)
        let fd = descriptor
        readSource.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard let self else { return }
            if count > 0 {
                let data = Data(buffer[0..<count])
                Task { await self.deliver(data) }
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                let code = errno
                Task { await self.fail(ChannelError.readFailed(errno: code)) }
            }
        }
        readSource.setCancelHandler {}
        source = readSource
        readSource.resume()
    }

    private func deliver(_ data: Data) {
        continuation?.yield(data)
    }

    private func fail(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}
