import Foundation

/// Numeric protocol fixtures only: no sockets, camera pixels or phone access.
@main enum FrameAcknowledgementTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func receipt(_ nanoseconds: Int64) -> Data {
        var encoded = nanoseconds.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
    static func rejects(_ data: Data, _ message: String) {
        do {
            _ = try PhoneSession.frameProcessingMilliseconds(in: data)
            fatalError(message)
        } catch is ScanError {
            // The protocol rejects malformed receipts through the product error type.
        } catch {
            fatalError("Unexpected error type for invalid frame acknowledgement")
        }
    }
    static func main() throws {
        let legacy = try PhoneSession.frameProcessingMilliseconds(in: Data())
        require(legacy == nil, "Legacy or deliberately ignored epoch ACK must remain compatible")

        // Literal bytes check wire order independently of the fixture encoder:
        // 0x075bcd15 = 123456789 nanoseconds = 123.456789 milliseconds.
        let duration = try PhoneSession.frameProcessingMilliseconds(in: Data([0, 0, 0, 0, 7, 91, 205, 21]))
        require(duration.map { abs($0 - 123.456789) < 0.000001 } == true,
                "Big-endian nanoseconds did not convert to milliseconds")
        let zero = try PhoneSession.frameProcessingMilliseconds(in: receipt(0))
        require(zero == 0, "An accepted zero-duration measurement became an absent receipt")
        let oneNanosecond = try PhoneSession.frameProcessingMilliseconds(in: receipt(1))
        require(oneNanosecond == 0.000001, "Sub-millisecond precision was truncated")
        let maximum = try PhoneSession.frameProcessingMilliseconds(in: receipt(Int64.max))
        require(maximum == Double(Int64.max) / 1_000_000, "Largest nonnegative Long was rejected or misread")

        for value: Int64 in [-1, -1_000_000, Int64.min] {
            rejects(receipt(value), "Negative Java Long duration accepted")
        }
        for length in [1, 2, 4, 7, 9, 16] {
            rejects(Data(repeating: 0, count: length), "Malformed ACK length accepted")
        }
        // Parsing must not assume a Data slice starts at collection index zero.
        let padded = Data([99]) + receipt(1_000_000) + Data([99])
        let sliced = try PhoneSession.frameProcessingMilliseconds(in: padded.dropFirst().dropLast())
        require(sliced == 1, "Valid sliced receipt lost byte alignment")
        print("PASS optional frame ACK: empty compatibility, big-endian nanoseconds/ms, zero/precision/range, negative values and invalid lengths")
    }
}
