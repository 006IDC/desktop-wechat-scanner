/** A failed old request must not poison a replacement stream/camera/epoch. */
final class CameraRequestScope {
    private final long stream, capture, epoch;
    CameraRequestScope(long stream,long capture,long epoch) {this.stream=stream;this.capture=capture;this.epoch=epoch;}
    boolean matches(CameraRequestScope other) {return other!=null && other.matches(stream,capture,epoch);}
    boolean matches(long stream,long capture,long epoch) {return this.stream==stream && this.capture==capture && this.epoch==epoch;}
}
