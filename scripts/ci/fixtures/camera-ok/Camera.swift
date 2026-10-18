import AVFoundation
import Vision
let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
let status = AVCaptureDevice.authorizationStatus(for: .video)
let request = VNRecognizeTextRequest()
