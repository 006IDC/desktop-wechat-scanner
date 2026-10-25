import Foundation
import CoreImage
import AppKit
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("make <png> <text> or read <image>") }
let url = URL(fileURLWithPath: args[2])
if args[1] == "make" {
    guard args.count == 4 else { fatalError("Missing payload") }
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(args[3].utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let ci = filter.outputImage!
    guard let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(ci, from: ci.extent) else {
        fputs("Core Image could not render the generated QR image\n", stderr)
        exit(1)
    }
    let scale = 12, padding = 48
    let side = cg.width * scale + padding * 2
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .none
    ctx.draw(cg, in: CGRect(x: padding, y: padding, width: cg.width * scale, height: cg.height * scale))
    let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    print("Generated synthetic QR image")
} else if args[1] == "read" {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(url: url).perform([request])
    let codes = (request.results ?? []).compactMap { $0.payloadStringValue }
    for code in codes { print(code) }
    if codes.isEmpty { exit(2) }
} else {
    fatalError("Unknown command")
}
