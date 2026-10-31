public final class CameraRequestScopeTests {
    public static void main(String[] args) {
        CameraRequestScope request=new CameraRequestScope(2,7,5);
        if(!request.matches(2,7,5) || request.matches(3,7,5) || request.matches(2,8,5) || request.matches(2,7,6)) throw new AssertionError();
        System.out.println("PASS failed old request cannot poison replaced stream, capture context or epoch");
    }
}
