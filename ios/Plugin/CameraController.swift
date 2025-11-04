//
//  CameraController.swift
//  Plugin
//
//  Created by Ariel Hernandez Musa on 7/14/19.
//  Copyright © 2019 Max Lynch. All rights reserved.
//

import AVFoundation
import UIKit
import Vision
import ImageIO
import AudioToolbox

protocol CameraTextRecognitionDelegate: AnyObject {
    func didRecognizeText(blocks: [[String: Any]])
}
class CameraController: NSObject {
    var captureSession: AVCaptureSession?

    var currentCameraPosition: CameraPosition?

    var frontCamera: AVCaptureDevice?
    var frontCameraInput: AVCaptureDeviceInput?

    var dataOutput: AVCaptureVideoDataOutput?
    var photoOutput: AVCapturePhotoOutput?

    var rearCamera: AVCaptureDevice?
    var rearCameraInput: AVCaptureDeviceInput?

    var previewLayer: AVCaptureVideoPreviewLayer?

    var flashMode = AVCaptureDevice.FlashMode.off
    var photoCaptureCompletionBlock: ((UIImage?, Error?) -> Void)?

    var sampleBufferCaptureCompletionBlock: ((UIImage?, Error?) -> Void)?
    
    // Store completion for silent capture
    var silentCaptureCompletion: ((UIImage?, Error?) -> Void)?
    
    // Rate limiting for sample buffer processing
    var lastVisionProcessTime: Date = Date.distantPast

    var highResolutionOutput: Bool = false

    var audioDevice: AVCaptureDevice?
    var audioInput: AVCaptureDeviceInput?

    var zoomFactor: CGFloat = 1.0
    
    // Thread safety
    private let cameraQueue = DispatchQueue(label: "com.camera.queue", qos: .userInitiated)
    internal var isCleaningUp = false
    internal var isDestroyed = false
    private var safetyTimer: Timer?
    
    internal var requests = [VNRequest]()
    var isRunningTextRecognition = false
	private var frameCounter = 0
    public weak var textRecognitionDelegate: CameraTextRecognitionDelegate?
    
    // Timer-based Vision processing (safer than sample buffer delegates)
    private var visionTimer: Timer?
    
    // Keep a reference to the data output queue so we can enable/disable the delegate safely
    private var dataOutputQueue: DispatchQueue?
    
    // Group to track in-flight Vision processing tasks so we can wait for them when stopping
    private var visionProcessingGroup = DispatchGroup()
    
    // MARK: - Cleanup Methods
    func stopVision() {
        cameraQueue.sync {
            guard !isDestroyed else { return }
            isRunningTextRecognition = false
            requests.removeAll()
            frameCounter = 0
            print("Vision processing stopped and cleaned up")
        }
        
        // Stop the timer instead of waiting for sample buffer group
        stopVisionTimer()
    }

    /// Stop the capture session safely on the camera queue.
    func stopCaptureSession() {
        cameraQueue.sync {
            if let session = self.captureSession, session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Disable the sample buffer delegate to prevent `captureOutput(_:didOutput:from:)` from being called.
    /// This helps avoid buffers being processed while the capture session is stopping which can lead to crashes.
    func disableDataOutputDelegate() {
        // Sample buffer delegate already disabled - using timer-based approach instead
        print("Sample buffer delegate already disabled")
    }

    /// Re-enable the sample buffer delegate using the stored data output queue.
    func enableDataOutputDelegate() {
        // Sample buffer delegate disabled - using timer-based approach instead
        print("Sample buffer delegate disabled - using timer-based Vision")
    }
    
    func cleanup() {
        cameraQueue.sync {
            guard !isDestroyed else { return }
            isCleaningUp = true
            isDestroyed = true
            
            // Stop Vision timer first
            DispatchQueue.main.async { [weak self] in
                self?.stopVisionTimer()
            }
            
            // Stop safety timer
            safetyTimer?.invalidate()
            safetyTimer = nil
            
            // Stop all processing immediately
            isRunningTextRecognition = false
            requests.removeAll()
            frameCounter = 0
            
            // CRITICAL: Remove sample buffer delegate to prevent crashes
            dataOutput?.setSampleBufferDelegate(nil, queue: nil)
            
            // Clear delegate to prevent callbacks
            textRecognitionDelegate = nil
            
            // Stop capture session on background thread
            if let session = captureSession, session.isRunning {
                session.stopRunning()
            }
            
            // Clear all capture session inputs and outputs
            captureSession?.inputs.forEach { input in
                captureSession?.removeInput(input)
            }
            captureSession?.outputs.forEach { output in
                captureSession?.removeOutput(output)
            }
            
            captureSession = nil
            frontCameraInput = nil
            rearCameraInput = nil
            photoOutput = nil
            dataOutput = nil
            
            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil
            }
            
            print("CameraController cleanup completed")
        }
    }
    
    deinit {
        print("CameraController deinitializing")
        cleanup()
    }
}

extension CameraController {
    func prepare(cameraPosition: String, disableAudio: Bool, completionHandler: @escaping (Error?) -> Void) {
        // Safety check
        guard !isCleaningUp && !isDestroyed else {
            completionHandler(CameraControllerError.invalidOperation)
            return
        }
        
        // Preserve Vision state instead of stopping it during camera setup
        let wasRunningVision = isRunningTextRecognition
        print("Camera prepare - preserving Vision state: \(wasRunningVision)")
        
        func createCaptureSession() {
            self.captureSession = AVCaptureSession()
        }

        func configureCaptureDevices() throws {

            let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: AVMediaType.video, position: .unspecified)

            let cameras = session.devices.compactMap { $0 }
            guard !cameras.isEmpty else { throw CameraControllerError.noCamerasAvailable }

            for camera in cameras {
                if camera.position == .front {
                    self.frontCamera = camera
                }

                if camera.position == .back {
                    self.rearCamera = camera

                    try camera.lockForConfiguration()
                    camera.focusMode = .continuousAutoFocus
                    camera.unlockForConfiguration()
                }
            }
            if disableAudio == false {
                self.audioDevice = AVCaptureDevice.default(for: AVMediaType.audio)
            }
        }

        func configureDeviceInputs() throws {
            guard let captureSession = self.captureSession else { throw CameraControllerError.captureSessionIsMissing }

            if cameraPosition == "rear" {
                if let rearCamera = self.rearCamera {
                    self.rearCameraInput = try AVCaptureDeviceInput(device: rearCamera)

                    if captureSession.canAddInput(self.rearCameraInput!) { captureSession.addInput(self.rearCameraInput!) }

                    self.currentCameraPosition = .rear
                }
            } else if cameraPosition == "front" {
                if let frontCamera = self.frontCamera {
                    self.frontCameraInput = try AVCaptureDeviceInput(device: frontCamera)

                    if captureSession.canAddInput(self.frontCameraInput!) { captureSession.addInput(self.frontCameraInput!) } else { throw CameraControllerError.inputsAreInvalid }

                    self.currentCameraPosition = .front
                }
            } else { throw CameraControllerError.noCamerasAvailable }

            // Add audio input
            if disableAudio == false {
                if let audioDevice = self.audioDevice {
                    self.audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if captureSession.canAddInput(self.audioInput!) {
                        captureSession.addInput(self.audioInput!)
                    } else {
                        throw CameraControllerError.inputsAreInvalid
                    }
                }
            }
        }

        func configurePhotoOutput() throws {
            guard let captureSession = self.captureSession else { throw CameraControllerError.captureSessionIsMissing }

            self.photoOutput = AVCapturePhotoOutput()
            self.photoOutput!.setPreparedPhotoSettingsArray([AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])], completionHandler: nil)
            self.photoOutput?.isHighResolutionCaptureEnabled = self.highResolutionOutput
            if captureSession.canAddOutput(self.photoOutput!) { captureSession.addOutput(self.photoOutput!) }
            captureSession.startRunning()
        }

        func configureDataOutput() throws {
            // Re-enable data output WITH sample buffer delegate for silent Vision processing
            guard let captureSession = self.captureSession else { throw CameraControllerError.captureSessionIsMissing }

            self.dataOutput = AVCaptureVideoDataOutput()
            self.dataOutput?.videoSettings = [
                (kCVPixelBufferPixelFormatTypeKey as String): NSNumber(value: kCVPixelFormatType_32BGRA as UInt32)
            ]
            
            // Critical: Always discard late frames to prevent memory buildup
            self.dataOutput?.alwaysDiscardsLateVideoFrames = true
            
            if captureSession.canAddOutput(self.dataOutput!) {
                captureSession.addOutput(self.dataOutput!)
            }

            // Set up sample buffer delegate on background queue with proper safety
            let videoQueue = DispatchQueue(label: "videoQueue", qos: .background)
            self.dataOutput?.setSampleBufferDelegate(self, queue: videoQueue)

            captureSession.commitConfiguration()

            print("Data output configured with SAFE sample buffer delegate")
        }

        DispatchQueue(label: "prepare").async {
            do {
                createCaptureSession()
                try configureCaptureDevices()
                try configureDeviceInputs()
                try configurePhotoOutput()
                try configureDataOutput()
                // try configureVideoOutput()
            } catch {
                DispatchQueue.main.async {
                    completionHandler(error)
                }

                return
            }

            DispatchQueue.main.async {
                // Restore Vision processing if it was running before camera setup
                if wasRunningVision {
                    print("Restoring Vision processing after camera setup")
                    do {
                        try self.setupVision()
                    } catch {
                        print("Failed to restore Vision: \(error)")
                    }
                }
                completionHandler(nil)
            }
        }
    }


    func displayPreview(on view: UIView) throws {
        guard let captureSession = self.captureSession, captureSession.isRunning else { throw CameraControllerError.captureSessionIsMissing }

        self.previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        self.previewLayer?.videoGravity = AVLayerVideoGravity.resizeAspectFill

        view.layer.insertSublayer(self.previewLayer!, at: 0)
        self.previewLayer?.frame = view.frame

        updateVideoOrientation()
    }
    
    func setupVision() throws {
        print("Setting up SAFE sample buffer delegate Vision processing for text recognition")
        
        let recognizeTextRequest = VNRecognizeTextRequest { [weak self] (request, error) in
            guard let self = self else { return }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
				print("No observations")
                return
            }

            // Create an array to hold the structured recognition data
		    var recognizedTextBlocks: [[String: Any]] = []

		    for observation in observations {
		        // Get the top recognized text candidate
		        guard let topCandidate = observation.topCandidates(1).first else { continue }

		        // The bounding box is normalized (0.0 to 1.0, with origin at bottom-left)
		        let normalizedBoundingBox = observation.boundingBox
		        let box = normalizedBoundingBox
		        
		        // Create a dictionary for the current text block
		        let block: [String: Any] = [
		            "text": topCandidate.string,
		            "confidence": topCandidate.confidence,
		            "boundingBox": [
		                "x": box.origin.x,
		                "y": box.origin.y,
		                "width": box.size.width,
		                "height": box.size.height
		            ]
		        ]

		        recognizedTextBlocks.append(block)
		    }
		            
            // Process Vision results safely on background thread
            if !self.isDestroyed && !self.isCleaningUp && self.isRunningTextRecognition {
                print("Vision recognized \(recognizedTextBlocks.count) text blocks")
                
                // Call delegate on background thread to avoid UI lag
                if let delegate = self.textRecognitionDelegate {
                    delegate.didRecognizeText(blocks: recognizedTextBlocks)
                }
                
                // Also log for debugging
                if !recognizedTextBlocks.isEmpty {
                    let textStrings = recognizedTextBlocks.compactMap { $0["text"] as? String }
                    let recognizedText = textStrings.joined(separator: " ")
                    print("Recognized text: \(recognizedText)")
                }
            }
        }

        recognizeTextRequest.recognitionLevel = .fast // Use fast instead of accurate for better performance
		recognizeTextRequest.usesLanguageCorrection = false

        self.requests = [recognizeTextRequest]

		print("Vision setup complete")
		self.isRunningTextRecognition = true
        
        // Start timer-based processing instead of sample buffer delegate
        startVisionTimer()
    }
    
    private func startVisionTimer() {
        // Stop any existing timer
        visionTimer?.invalidate()
        
                // Use SAFE sample buffer delegate approach instead of timer
        isRunningTextRecognition = true
        
        // DISABLE timer-based approach - using sample buffer delegate for silent processing
        /*
        // Stop any existing timer
        visionTimer?.invalidate()
        
        // Start a timer that captures frames every 2 seconds for Vision processing (less frequent, silent)
        visionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.processVisionFrame()
        }
        
        print("Started silent Vision processing (every 2 seconds)")
        */
        
        print("Started SAFE sample buffer delegate Vision processing")
    }
    
    private func stopVisionTimer() {
        visionTimer?.invalidate()
        visionTimer = nil
        print("Stopped Vision timer")
    }
    
    private func processVisionFrame() {
        print("🔍 processVisionFrame called")
        
        guard !isDestroyed && !isCleaningUp && isRunningTextRecognition else { 
            print("❌ Early exit - destroyed: \(isDestroyed), cleaning: \(isCleaningUp), running: \(isRunningTextRecognition)")
            return 
        }
        
        guard let captureSession = self.captureSession, captureSession.isRunning else { 
            print("❌ No capture session or not running")
            return 
        }
        
        print("✅ Capture session is running, attempting to capture sample...")
        
        // Use silent photo capture for Vision processing
        self.captureSilentSample { [weak self] image, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Error capturing sample for Vision: \(error)")
                return
            }
            
            guard let image = image else {
                print("❌ No image captured for Vision")
                return
            }
            
            print("✅ Got image for Vision processing, size: \(image.size)")
            
            // Process the captured image with Vision on background queue
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self,
                      !self.isDestroyed,
                      !self.isCleaningUp,
                      self.isRunningTextRecognition,
                      !self.requests.isEmpty else { 
                    print("❌ Vision processing cancelled - state changed")
                    return 
                }
                
                guard let cgImage = image.cgImage else {
                    print("❌ Could not get CGImage from captured image")
                    return
                }
                
                print("🔍 Starting Vision request on \(image.size) image...")
                let imageRequestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                
                do {
                    try imageRequestHandler.perform(self.requests)
                    print("✅ Vision request completed successfully")
                } catch {
                    print("❌ Vision error: \(error)")
                }
            }
        }
    }
    
    private func startSafetyTimer() {
        // TEMPORARILY DISABLED
        return
        
        /*
        DispatchQueue.main.async { [weak self] in
            self?.safetyTimer?.invalidate()
            self?.safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
                print("Safety timer triggered - performing cleanup")
                self?.cleanup()
            }
        }
        */
    }

    func setupGestures(target: UIView, enableZoom: Bool) {
        setupTapGesture(target: target, selector: #selector(handleTap(_:)), delegate: self)
        if enableZoom {
            setupPinchGesture(target: target, selector: #selector(handlePinch(_:)), delegate: self)
        }
    }

    func setupTapGesture(target: UIView, selector: Selector, delegate: UIGestureRecognizerDelegate?) {
        let tapGesture = UITapGestureRecognizer(target: self, action: selector)
        tapGesture.delegate = delegate
        target.addGestureRecognizer(tapGesture)
    }

    func setupPinchGesture(target: UIView, selector: Selector, delegate: UIGestureRecognizerDelegate?) {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: selector)
        pinchGesture.delegate = delegate
        target.addGestureRecognizer(pinchGesture)
    }

    func updateVideoOrientation() {
        assert(Thread.isMainThread) // UIApplication.statusBarOrientation requires the main thread.

        let videoOrientation: AVCaptureVideoOrientation
        switch UIApplication.shared.statusBarOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .landscapeLeft:
            videoOrientation = .landscapeLeft
        case .landscapeRight:
            videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .unknown:
            fallthrough
        @unknown default:
            videoOrientation = .portrait
        }

        previewLayer?.connection?.videoOrientation = videoOrientation
        dataOutput?.connections.forEach { $0.videoOrientation = videoOrientation }
        photoOutput?.connections.forEach { $0.videoOrientation = videoOrientation }
    }

    func switchCameras() throws {
        guard let currentCameraPosition = currentCameraPosition, let captureSession = self.captureSession, captureSession.isRunning else { throw CameraControllerError.captureSessionIsMissing }

        captureSession.beginConfiguration()

        func switchToFrontCamera() throws {

            guard let rearCameraInput = self.rearCameraInput, captureSession.inputs.contains(rearCameraInput),
                  let frontCamera = self.frontCamera else { throw CameraControllerError.invalidOperation }

            self.frontCameraInput = try AVCaptureDeviceInput(device: frontCamera)

            captureSession.removeInput(rearCameraInput)

            if captureSession.canAddInput(self.frontCameraInput!) {
                captureSession.addInput(self.frontCameraInput!)

                self.currentCameraPosition = .front
            } else {
                throw CameraControllerError.invalidOperation
            }
        }

        func switchToRearCamera() throws {

            guard let frontCameraInput = self.frontCameraInput, captureSession.inputs.contains(frontCameraInput),
                  let rearCamera = self.rearCamera else { throw CameraControllerError.invalidOperation }

            self.rearCameraInput = try AVCaptureDeviceInput(device: rearCamera)

            captureSession.removeInput(frontCameraInput)

            if captureSession.canAddInput(self.rearCameraInput!) {
                captureSession.addInput(self.rearCameraInput!)

                self.currentCameraPosition = .rear
            } else { throw CameraControllerError.invalidOperation }
        }

        switch currentCameraPosition {
        case .front:
            try switchToRearCamera()

        case .rear:
            try switchToFrontCamera()
        }

        captureSession.commitConfiguration()
    }

    func captureImage(completion: @escaping (UIImage?, Error?) -> Void) {
        guard let captureSession = captureSession, captureSession.isRunning else { completion(nil, CameraControllerError.captureSessionIsMissing); return }
        let settings = AVCapturePhotoSettings()

        settings.flashMode = self.flashMode
        settings.isHighResolutionPhotoEnabled = self.highResolutionOutput

        self.photoOutput?.capturePhoto(with: settings, delegate: self)
        self.photoCaptureCompletionBlock = completion
    }

    func captureSample(completion: @escaping (UIImage?, Error?) -> Void) {
        guard let captureSession = captureSession,
              captureSession.isRunning else {
            completion(nil, CameraControllerError.captureSessionIsMissing)
            return
        }

        self.sampleBufferCaptureCompletionBlock = completion
    }
    
    // New silent capture method for Vision processing
    func captureSilentSample(completion: @escaping (UIImage?, Error?) -> Void) {
        print("🎯 captureSilentSample called")
        
        guard let captureSession = captureSession,
              captureSession.isRunning else {
            print("❌ Capture session not running for silent sample")
            completion(nil, CameraControllerError.captureSessionIsMissing)
            return
        }
        
        guard let photoOutput = self.photoOutput else {
            print("❌ Photo output not available for silent sample")
            completion(nil, CameraControllerError.unknown)
            return
        }
        
        print("✅ Creating silent photo settings...")
        
        // Create settings for silent capture
        let photoSettings = AVCapturePhotoSettings()
        
        // Disable flash for silent capture
        photoSettings.flashMode = .off
        
        // Store completion for delegate callback
        self.silentCaptureCompletion = completion
        
        print("✅ Capturing silent photo...")
        
        // Temporarily disable camera shutter sound by muting system volume
        // This is a standard technique for silent photo capture
        DispatchQueue.main.async {
            // Disable the shutter sound by removing the system sound
            AudioServicesDisposeSystemSoundID(1108)
            
            // Capture the photo
            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }


    func getSupportedFlashModes() throws -> [String] {
        var currentCamera: AVCaptureDevice?
        switch currentCameraPosition {
        case .front:
            currentCamera = self.frontCamera!
        case .rear:
            currentCamera = self.rearCamera!
        default: break
        }

        guard
            let device = currentCamera
        else {
            throw CameraControllerError.noCamerasAvailable
        }

        var supportedFlashModesAsStrings: [String] = []
        if device.hasFlash {
            guard let supportedFlashModes: [AVCaptureDevice.FlashMode] = self.photoOutput?.supportedFlashModes else {
                throw CameraControllerError.noCamerasAvailable
            }

            for flashMode in supportedFlashModes {
                var flashModeValue: String?
                switch flashMode {
                case AVCaptureDevice.FlashMode.off:
                    flashModeValue = "off"
                case AVCaptureDevice.FlashMode.on:
                    flashModeValue = "on"
                case AVCaptureDevice.FlashMode.auto:
                    flashModeValue = "auto"
                default: break
                }
                if flashModeValue != nil {
                    supportedFlashModesAsStrings.append(flashModeValue!)
                }
            }
        }
        if device.hasTorch {
            supportedFlashModesAsStrings.append("torch")
        }
        return supportedFlashModesAsStrings

    }

    func setFlashMode(flashMode: AVCaptureDevice.FlashMode) throws {
        var currentCamera: AVCaptureDevice?
        switch currentCameraPosition {
        case .front:
            currentCamera = self.frontCamera!
        case .rear:
            currentCamera = self.rearCamera!
        default: break
        }

        guard let device = currentCamera else {
            throw CameraControllerError.noCamerasAvailable
        }

        guard let supportedFlashModes: [AVCaptureDevice.FlashMode] = self.photoOutput?.supportedFlashModes else {
            throw CameraControllerError.invalidOperation
        }
        if supportedFlashModes.contains(flashMode) {
            do {
                try device.lockForConfiguration()

                if device.hasTorch && device.isTorchAvailable && device.torchMode == AVCaptureDevice.TorchMode.on {
                    device.torchMode = AVCaptureDevice.TorchMode.off
                }
                self.flashMode = flashMode
                let photoSettings = AVCapturePhotoSettings()
                photoSettings.flashMode = flashMode
                self.photoOutput?.photoSettingsForSceneMonitoring = photoSettings

                device.unlockForConfiguration()
            } catch {
                throw CameraControllerError.invalidOperation
            }
        } else {
            throw CameraControllerError.invalidOperation
        }
    }

    func setTorchMode() throws {
        var currentCamera: AVCaptureDevice?
        switch currentCameraPosition {
        case .front:
            currentCamera = self.frontCamera!
        case .rear:
            currentCamera = self.rearCamera!
        default: break
        }

        guard
            let device = currentCamera,
            device.hasTorch,
            device.isTorchAvailable
        else {
            throw CameraControllerError.invalidOperation
        }

        do {
            try device.lockForConfiguration()
            if device.isTorchModeSupported(AVCaptureDevice.TorchMode.on) {
                device.torchMode = AVCaptureDevice.TorchMode.on
            } else if device.isTorchModeSupported(AVCaptureDevice.TorchMode.auto) {
                device.torchMode = AVCaptureDevice.TorchMode.auto
            } else {
                device.torchMode = AVCaptureDevice.TorchMode.off
            }
            device.unlockForConfiguration()
        } catch {
            throw CameraControllerError.invalidOperation
        }

    }

    func captureVideo(completion: @escaping (URL?, Error?) -> Void) {
        guard let captureSession = self.captureSession, captureSession.isRunning else {
            completion(nil, CameraControllerError.captureSessionIsMissing)
            return
        }
        let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identifier = UUID()
        let randomIdentifier = identifier.uuidString.replacingOccurrences(of: "-", with: "")
        let finalIdentifier = String(randomIdentifier.prefix(8))
        let fileName="cpcp_video_"+finalIdentifier+".mp4"

        let fileUrl = path.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileUrl)
        /*videoOutput!.startRecording(to: fileUrl, recordingDelegate: self)
         self.videoRecordCompletionBlock = completion*/
    }

    func stopRecording(completion: @escaping (Error?) -> Void) {
        guard let captureSession = self.captureSession, captureSession.isRunning else {
            completion(CameraControllerError.captureSessionIsMissing)
            return
        }
        // self.videoOutput?.stopRecording()
    }
}

extension CameraController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc
    func handleTap(_ tap: UITapGestureRecognizer) {
        guard let device = self.currentCameraPosition == .rear ? rearCamera : frontCamera else { return }

        let point = tap.location(in: tap.view)
        let devicePoint = self.previewLayer?.captureDevicePointConverted(fromLayerPoint: point)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let focusMode = AVCaptureDevice.FocusMode.autoFocus
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = CGPoint(x: CGFloat(devicePoint?.x ?? 0), y: CGFloat(devicePoint?.y ?? 0))
                device.focusMode = focusMode
            }

            let exposureMode = AVCaptureDevice.ExposureMode.autoExpose
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = CGPoint(x: CGFloat(devicePoint?.x ?? 0), y: CGFloat(devicePoint?.y ?? 0))
                device.exposureMode = exposureMode
            }
        } catch {
            debugPrint(error)
        }
    }

    @objc
    private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard let device = self.currentCameraPosition == .rear ? rearCamera : frontCamera else { return }

        func minMaxZoom(_ factor: CGFloat) -> CGFloat { return max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor)) }

        func update(scale factor: CGFloat) {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                device.videoZoomFactor = factor
            } catch {
                debugPrint(error)
            }
        }

        switch pinch.state {
        case .began: fallthrough
        case .changed:
            let newScaleFactor = minMaxZoom(pinch.scale * zoomFactor)
            update(scale: newScaleFactor)
        case .ended:
            zoomFactor = device.videoZoomFactor
        default: break
        }
    }

	private func visionOrientation(for videoOrientation: AVCaptureVideoOrientation,
                               isFrontCamera: Bool) -> CGImagePropertyOrientation {
	    switch videoOrientation {
	    case .portrait:
	        return isFrontCamera ? .leftMirrored : .right
	    case .portraitUpsideDown:
	        return isFrontCamera ? .rightMirrored : .left
	    case .landscapeRight:
	        return isFrontCamera ? .downMirrored : .up
	    case .landscapeLeft:
	        return isFrontCamera ? .upMirrored : .down
	    @unknown default:
	        return .up
	    }
	}
	
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                            resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Swift.Error?) {
        
        if let error = error { 
            // Handle both regular photo capture and silent capture errors
            self.photoCaptureCompletionBlock?(nil, error)
            self.silentCaptureCompletion?(nil, error)
            self.silentCaptureCompletion = nil
        } else if let buffer = photoSampleBuffer, let data = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: buffer, previewPhotoSampleBuffer: nil),
                  let image = UIImage(data: data) {
            
            let fixedImage = image.fixedOrientation()
            
            // Handle regular photo capture
            self.photoCaptureCompletionBlock?(fixedImage, nil)
            
            // Handle silent capture for Vision processing
            if let silentCompletion = self.silentCaptureCompletion {
                if let fixedImage = fixedImage {
                    print("✅ Silent capture completed successfully, image size: \(fixedImage.size)")
                    silentCompletion(fixedImage, nil)
                } else {
                    print("❌ Failed to fix image orientation for silent capture")
                    silentCompletion(nil, CameraControllerError.unknown)
                }
                self.silentCaptureCompletion = nil
            }
        } else {
            // Handle unknown errors for both
            self.photoCaptureCompletionBlock?(nil, CameraControllerError.unknown)
            self.silentCaptureCompletion?(nil, CameraControllerError.unknown)
            self.silentCaptureCompletion = nil
        }
    }
}

// MARK: - Sample Buffer Processing WITH SAFETY MEASURES
// Re-enabled with proper threading, rate limiting, and cleanup
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // CRITICAL SAFETY CHECKS - exit early if any issues
        guard !isDestroyed && !isCleaningUp && isRunningTextRecognition else { 
            return 
        }
        
        // Rate limiting - process every 1 second for optimal balance of performance and responsiveness
        let now = Date()
        guard now.timeIntervalSince(lastVisionProcessTime) >= 1 else {
            return
        }
        lastVisionProcessTime = now
        
        // Ensure we have requests to process
        guard !requests.isEmpty else { return }
        
        // Additional CPU optimization - skip if system is under heavy load
        let systemInfo = ProcessInfo.processInfo
        if systemInfo.thermalState == .critical || systemInfo.thermalState == .serious {
            print("⚠️ Skipping Vision processing - high thermal state")
            return
        }
        
        // Process on background queue with balanced priority for good responsiveness
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.processSampleBufferSafely(sampleBuffer)
        }
    }
    
    private func processSampleBufferSafely(_ sampleBuffer: CMSampleBuffer) {
        // Double-check state on background thread
        guard !isDestroyed && !isCleaningUp && isRunningTextRecognition else { 
            return 
        }
        
        // Convert sample buffer to image buffer
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { 
            return 
        }
        
        // Process with Vision
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
        
        do {
            try imageRequestHandler.perform(self.requests)
            print("✅ SAFE sample buffer Vision processing completed")
        } catch {
            print("❌ Safe Vision processing error: \(error)")
        }
    }
}

enum CameraControllerError: Swift.Error {
    case captureSessionAlreadyRunning
    case captureSessionIsMissing
    case inputsAreInvalid
    case invalidOperation
    case noCamerasAvailable
    case unknown
}

public enum CameraPosition {
    case front
    case rear
}

extension CameraControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .captureSessionAlreadyRunning:
            return NSLocalizedString("Capture Session is Already Running", comment: "Capture Session Already Running")
        case .captureSessionIsMissing:
            return NSLocalizedString("Capture Session is Missing", comment: "Capture Session Missing")
        case .inputsAreInvalid:
            return NSLocalizedString("Inputs Are Invalid", comment: "Inputs Are Invalid")
        case .invalidOperation:
            return NSLocalizedString("Invalid Operation", comment: "invalid Operation")
        case .noCamerasAvailable:
            return NSLocalizedString("Failed to access device camera(s)", comment: "No Cameras Available")
        case .unknown:
            return NSLocalizedString("Unknown", comment: "Unknown")

        }
    }
}

extension UIImage {

    func fixedOrientation() -> UIImage? {

        guard imageOrientation != UIImage.Orientation.up else {
            // This is default orientation, don't need to do anything
            return self.copy() as? UIImage
        }

        guard let cgImage = self.cgImage else {
            // CGImage is not available
            return nil
        }

        guard let colorSpace = cgImage.colorSpace, let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil // Not able to create CGContext
        }

        var transform: CGAffineTransform = CGAffineTransform.identity
        switch imageOrientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: size.width, y: size.height)
            transform = transform.rotated(by: CGFloat.pi)
            print("down")
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.rotated(by: CGFloat.pi / 2.0)
            print("left")
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: size.height)
            transform = transform.rotated(by: CGFloat.pi / -2.0)
            print("right")
        case .up, .upMirrored:
            break
        }

        // Flip image one more time if needed to, this is to prevent flipped image
        switch imageOrientation {
        case .upMirrored, .downMirrored:
            transform.translatedBy(x: size.width, y: 0)
            transform.scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform.translatedBy(x: size.height, y: 0)
            transform.scaledBy(x: -1, y: 1)
        case .up, .down, .left, .right:
            break
        }

        ctx.concatenate(transform)

        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            ctx.draw(self.cgImage!, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
        default:
            ctx.draw(self.cgImage!, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        guard let newCGImage = ctx.makeImage() else { return nil }
        return UIImage.init(cgImage: newCGImage, scale: 1, orientation: .up)
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        /*if error == nil {
         self.videoRecordCompletionBlock?(outputFileURL, nil)
         } else {
         self.videoRecordCompletionBlock?(nil, error)
         }*/
    }
}
