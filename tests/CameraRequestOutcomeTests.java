public final class CameraRequestOutcomeTests {
    static void require(boolean value) {if (!value) throw new AssertionError();}
    public static void main(String[] args) {
        require(CameraRequestOutcome.classify(false,true,true,true)==CameraRequestOutcome.Value.POSTED);
        require(CameraRequestOutcome.classify(false,true,true,false)==CameraRequestOutcome.Value.FAILED);
        // A blocked old painter can resume after Surface invalidation, before
        // its close notification removes the map entry. A replacement lives on.
        require(CameraRequestOutcome.classify(false,true,false,false)==CameraRequestOutcome.Value.RETIRED);
        require(CameraRequestOutcome.classify(false,false,true,false)==CameraRequestOutcome.Value.RETIRED);
        require(CameraRequestOutcome.classify(true,true,true,false)==CameraRequestOutcome.Value.RETIRED);
        System.out.println("PASS invalid/closed/replaced Surface retires without poisoning replacement; current post failure is fatal");
    }
}
