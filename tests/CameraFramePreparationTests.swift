import Foundation

private actor PreparationProbe {
    var imageStarted=false,clearStarted=false,clearAcknowledged=false,imageCancelled=false
    func startImage(){imageStarted=true}
    func startClear(){clearStarted=true}
    func acknowledge(){clearAcknowledged=true}
    func cancelImage(){imageCancelled=true}
}
@main enum CameraFramePreparationTests {
    enum Failure:Error {case image,clear,timeout}
    static func main() async throws {
        let parallel=PreparationProbe()
        let result=try await CameraFramePreparation.run(image:{
            await parallel.startImage()
            for _ in 0..<100 {
                if await parallel.clearStarted {return Data([7])}
                try await Task.sleep(nanoseconds:1_000_000)
            };throw Failure.timeout
        },clear:{
            await parallel.startClear()
            for _ in 0..<100 {
                if await parallel.imageStarted {await parallel.acknowledge();return 12}
                try await Task.sleep(nanoseconds:1_000_000)
            };throw Failure.timeout
        })
        precondition(result.image==Data([7]) && result.clearMilliseconds==12)
        let acknowledged=await parallel.clearAcknowledged;precondition(acknowledged)

        let captureFailure=PreparationProbe()
        do {
            _=try await CameraFramePreparation.run(image:{throw Failure.image},clear:{
                try await Task.sleep(nanoseconds:10_000_000)
                await captureFailure.acknowledge();return 10
            });preconditionFailure("Failed capture returned image bytes")
        } catch Failure.image {} catch {throw error}
        let waitedForClear=await captureFailure.clearAcknowledged;precondition(waitedForClear,"Capture failure abandoned the in-flight clear")

        let clearFailure=PreparationProbe()
        do {
            _=try await CameraFramePreparation.run(image:{
                await clearFailure.startImage()
                do {try await Task.sleep(nanoseconds:100_000_000)}
                catch {await clearFailure.cancelImage();throw error}
                return Data([9])
            },clear:{
                for _ in 0..<100 {
                    if await clearFailure.imageStarted {throw Failure.clear}
                    try await Task.sleep(nanoseconds:1_000_000)
                };throw Failure.timeout
            });preconditionFailure("Unconfirmed clear admitted image bytes")
        } catch let failure as CameraFramePreparation.ClearFailure {
            guard case Failure.clear=failure.underlying else{throw failure}
        }
        let imageCancelled=await clearFailure.imageCancelled;precondition(imageCancelled,"Clear failure leaked its image child")
        print("PASS image/clear overlap, clear-before-admission, error priority and structured cancellation")
    }
}
