/** Classify only a completed producer attempt; retirement is not a new-stream fault. */
final class CameraRequestOutcome {
    enum Value { POSTED, RETIRED, FAILED }
    static Value classify(boolean stopping, boolean sameSurface, boolean surfaceValid, boolean posted) {
        if (stopping || !sameSurface || !surfaceValid) return Value.RETIRED;
        return posted ? Value.POSTED : Value.FAILED;
    }
}
