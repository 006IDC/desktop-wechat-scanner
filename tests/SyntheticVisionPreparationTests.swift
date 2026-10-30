import Foundation

@main enum SyntheticVisionPreparationTests {
    @MainActor static func main() async throws {
        let cancelled=Task { @MainActor in try SyntheticVisionPreparation.run() }
        cancelled.cancel()
        do {_=try await cancelled.value;preconditionFailure("Cancelled preparation performed work")}
        catch is CancellationError {}
        let result=try SyntheticVisionPreparation.run()
        precondition(result.textMilliseconds.isFinite && result.textMilliseconds>=0)
        precondition(result.barcodeMilliseconds.isFinite && result.barcodeMilliseconds>=0)
        precondition(result.totalMilliseconds>=result.textMilliseconds+result.barcodeMilliseconds)
        print("PASS cancelled preparation and independent synthetic Chinese/English text and exact QR; no phone, capture, input or ordered window")
    }
}
