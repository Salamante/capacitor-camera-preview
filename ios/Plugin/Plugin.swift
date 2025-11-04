import Foundation
import Capacitor
import AVFoundation
/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitor.ionicframework.com/docs/plugins/ios
 */
@objc(CameraPreview)
public class CameraPreview: CAPPlugin{

    var previewView: UIView!
    var cameraPosition = String()
    let cameraController = CameraController()
    // swiftlint:disable identifier_name
    var x: CGFloat?
    var y: CGFloat?
    // swiftlint:enable identifier_name
    var width: CGFloat?
    var height: CGFloat?
    var paddingBottom: CGFloat?
    var rotateWhenOrientationChanged: Bool?
    var toBack: Bool?
    var storeToFile: Bool?
    var enableZoom: Bool?
    var highResolutionOutput: Bool = false
    var disableAudio: Bool = false

    var currentReadCaptureCall: CAPPluginCall?
    
    // MARK: - Overlay properties
    var overlayView: CameraOverlayView?
    var showOverlay: Bool = false
    var overlayDocumentType: String = "idCard"
    var overlayBorderColor: String = "#FFFFFF"
    var overlayBackgroundColor: String = "#00000080"
    var overlayLabelText: String = ""

    deinit {
        print("CameraPreview plugin deinitializing - cleaning up resources")
        
        // Capture references for cleanup
        let cameraController = self.cameraController
        let overlayView = self.overlayView
        
        // Remove observers immediately
        NotificationCenter.default.removeObserver(self)
        
        // Ensure cleanup happens on main thread
        DispatchQueue.main.async {
            // Clean up overlay
            overlayView?.removeFromSuperview()
            
            // Clean up camera controller
            cameraController.cleanup()
        }
    }


    @objc func rotated() {
        let height = self.paddingBottom != nil ? self.height! - self.paddingBottom!: self.height!

        if UIApplication.shared.statusBarOrientation.isLandscape {
            self.previewView.frame = CGRect(x: self.y!, y: self.x!, width: max(height, self.width!), height: min(height, self.width!))
            self.cameraController.previewLayer?.frame = self.previewView.frame
        }

        if UIApplication.shared.statusBarOrientation.isPortrait {
            if self.previewView != nil && self.x != nil && self.y != nil && self.width != nil && self.height != nil {
                self.previewView.frame = CGRect(x: self.x!, y: self.y!, width: min(height, self.width!), height: max(height, self.width!))
            }
            self.cameraController.previewLayer?.frame = self.previewView.frame
        }

        cameraController.updateVideoOrientation()
        
        // Update overlay frame and cutout if overlay is visible
        if let overlayView = self.overlayView {
            overlayView.frame = self.previewView.frame
            self.updateOverlayForCurrentOrientation()
        }
    }

    @objc func start(_ call: CAPPluginCall) {
		cameraController.textRecognitionDelegate = self
        self.cameraPosition = call.getString("position") ?? "rear"
        self.highResolutionOutput = call.getBool("enableHighResolution") ?? false
        self.cameraController.highResolutionOutput = self.highResolutionOutput

        if call.getInt("width") != nil {
            self.width = CGFloat(call.getInt("width")!)
        } else {
            self.width = UIScreen.main.bounds.size.width
        }
        if call.getInt("height") != nil {
            self.height = CGFloat(call.getInt("height")!)
        } else {
            self.height = UIScreen.main.bounds.size.height
        }
        self.x = call.getInt("x") != nil ? CGFloat(call.getInt("x")!)/UIScreen.main.scale: 0
        self.y = call.getInt("y") != nil ? CGFloat(call.getInt("y")!)/UIScreen.main.scale: 0
        if call.getInt("paddingBottom") != nil {
            self.paddingBottom = CGFloat(call.getInt("paddingBottom")!)
        }

        self.rotateWhenOrientationChanged = call.getBool("rotateWhenOrientationChanged") ?? true
        self.toBack = call.getBool("toBack") ?? false
        self.storeToFile = call.getBool("storeToFile") ?? false
        self.enableZoom = call.getBool("enableZoom") ?? false
        self.disableAudio = call.getBool("disableAudio") ?? false
        
        // MARK: - Overlay configuration
        self.showOverlay = call.getBool("showOverlay") ?? false
        self.overlayDocumentType = call.getString("overlayDocumentType") ?? "idCard"
        self.overlayBorderColor = call.getString("overlayBorderColor") ?? "#FFFFFF"
        self.overlayBackgroundColor = call.getString("overlayBackgroundColor") ?? "#00000080"
        self.overlayLabelText = call.getString("overlayLabelText") ?? ""

        AVCaptureDevice.requestAccess(for: .video, completionHandler: { (granted: Bool) in
            guard granted else {
                call.reject("permission failed")
                return
            }

            DispatchQueue.main.async {
                if self.cameraController.captureSession?.isRunning ?? false {
                    call.reject("camera already started")
                } else {
                    self.startCameraSession(call)
                }
            }
        })
    }
    
    private func startCameraSession(_ call: CAPPluginCall) {
        self.cameraController.prepare(cameraPosition: self.cameraPosition, disableAudio: self.disableAudio) { error in
            if let error = error {
                print("Error at 88: \(error)")
                call.reject(error.localizedDescription)
                return
            }
            let height = self.paddingBottom != nil ? self.height! - self.paddingBottom!: self.height!
            self.previewView = UIView(frame: CGRect(x: self.x ?? 0, y: self.y ?? 0, width: self.width!, height: height))
            self.webView?.isOpaque = false
            self.webView?.backgroundColor = UIColor.clear
            self.webView?.scrollView.backgroundColor = UIColor.clear
            self.webView?.superview?.addSubview(self.previewView)
            if self.toBack! {
                self.webView?.superview?.bringSubviewToFront(self.webView!)
            }
            try? self.cameraController.displayPreview(on: self.previewView)

            let frontView = self.toBack! ? self.webView : self.previewView
            self.cameraController.setupGestures(target: frontView ?? self.previewView, enableZoom: self.enableZoom!)
            
            // MARK: - Setup overlay if enabled
            if self.showOverlay {
                self.setupOverlay()
            }
            
            // Update debug message to reflect current Vision state
            let visionStatus = self.cameraController.isRunningTextRecognition ? "enabled" : "disabled"
            print("Camera started with overlay and Vision \(visionStatus)")

            if self.rotateWhenOrientationChanged == true {
                NotificationCenter.default.addObserver(self, selector: #selector(CameraPreview.rotated), name: UIDevice.orientationDidChangeNotification, object: nil)
            }

            call.resolve()
        }
    }


    @objc func flip(_ call: CAPPluginCall) {
        do {
            // Stop Vision processing temporarily while switching cameras
            let wasRunningVision = self.cameraController.isRunningTextRecognition
            if wasRunningVision {
                // prevent new buffers from being delivered while we switch
                self.cameraController.disableDataOutputDelegate()
                self.cameraController.stopVision()
            }
            
            try self.cameraController.switchCameras()
            
            // Restart Vision if it was running before
            if wasRunningVision {
                // re-enable sample buffer delegate before resuming vision
                self.cameraController.enableDataOutputDelegate()
                try self.cameraController.setupVision()
            }
            
            call.resolve()
        } catch {
            call.reject("failed to flip camera: \(error.localizedDescription)")
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
    // Stop Vision processing first and disable data callbacks to avoid in-flight buffers
    cameraController.disableDataOutputDelegate()
    cameraController.stopVision()
        
        guard self.cameraController.captureSession?.isRunning ?? false else {
            call.resolve()
            return
        }
        
        // Remove observers
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        
        // Stop camera session immediately (use camera controller to handle threading)
        self.cameraController.stopCaptureSession()
        
        // Clean up UI on main thread if needed
        if Thread.isMainThread {
            self.cleanupUI()
        } else {
            DispatchQueue.main.sync {
                self.cleanupUI()
            }
        }
        
        call.resolve()
    }
    
    private func cleanupUI() {
        // Clean up overlay
        if let overlay = self.overlayView {
            overlay.removeFromSuperview()
            self.overlayView = nil
        }
        
        // Clean up preview view
        if let preview = self.previewView {
            preview.removeFromSuperview()
            self.previewView = nil
        }
        
        self.webView?.isOpaque = true
    }
    
    // Get user's cache directory path
    @objc func getTempFilePath() -> URL {
        let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identifier = UUID()
        let randomIdentifier = identifier.uuidString.replacingOccurrences(of: "-", with: "")
        let finalIdentifier = String(randomIdentifier.prefix(8))
        let fileName="cpcp_capture_"+finalIdentifier+".jpg"
        let fileUrl=path.appendingPathComponent(fileName)
        return fileUrl
    }

    @objc func capture(_ call: CAPPluginCall) {
        DispatchQueue.main.async {

            let quality: Int? = call.getInt("quality", 85)

            self.cameraController.captureImage { (image, error) in

                guard let image = image else {
                    print(error ?? "Image capture error")
                    guard let error = error else {
                        call.reject("Image capture error")
                        return
                    }
                    call.reject(error.localizedDescription)
                    return
                }
                let imageData: Data?
                if self.cameraController.currentCameraPosition == .front {
                    let flippedImage = image.withHorizontallyFlippedOrientation()
                    imageData = flippedImage.jpegData(compressionQuality: CGFloat(quality!/100))
                } else {
                    imageData = image.jpegData(compressionQuality: CGFloat(quality!/100))
                }

                if self.storeToFile == false {
                    let imageBase64 = imageData?.base64EncodedString()
                    call.resolve(["value": imageBase64!])
                } else {
                    do {
                        let fileUrl=self.getTempFilePath()
                        try imageData?.write(to: fileUrl)
                        call.resolve(["value": fileUrl.absoluteString])
                    } catch {
                        call.reject("error writing image to file")
                    }
                }
            }
        }
    }

    @objc func captureSample(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let quality: Int? = call.getInt("quality", 85)

            self.cameraController.captureSample { image, error in
                guard let image = image else {
                    print("Image capture error: \(String(describing: error))")
                    call.reject("Image capture error: \(String(describing: error))")
                    return
                }

                let imageData: Data?
                if self.cameraPosition == "front" {
                    let flippedImage = image.withHorizontallyFlippedOrientation()
                    imageData = flippedImage.jpegData(compressionQuality: CGFloat(quality!/100))
                } else {
                    imageData = image.jpegData(compressionQuality: CGFloat(quality!/100))
                }

                if self.storeToFile == false {
                    let imageBase64 = imageData?.base64EncodedString()
                    call.resolve(["value": imageBase64!])
                } else {
                    do {
                        let fileUrl = self.getTempFilePath()
                        try imageData?.write(to: fileUrl)
                        call.resolve(["value": fileUrl.absoluteString])
                    } catch {
                        call.reject("Error writing image to file")
                    }
                }
            }
        }
    }
    
    @objc func readCapture(_ call: CAPPluginCall) {
        do {
            try self.cameraController.setupVision()
			print("readCapture Method Called")
			call.resolve()
        } catch {
            call.reject("readCapture error")
        }
    }

    @objc func getSupportedFlashModes(_ call: CAPPluginCall) {
        do {
            let supportedFlashModes = try self.cameraController.getSupportedFlashModes()
            call.resolve(["result": supportedFlashModes])
        } catch {
            call.reject("failed to get supported flash modes")
        }
    }

    @objc func setFlashMode(_ call: CAPPluginCall) {
        guard let flashMode = call.getString("flashMode") else {
            call.reject("failed to set flash mode. required parameter flashMode is missing")
            return
        }
        do {
            var flashModeAsEnum: AVCaptureDevice.FlashMode?
            switch flashMode {
            case "off":
                flashModeAsEnum = AVCaptureDevice.FlashMode.off
            case "on":
                flashModeAsEnum = AVCaptureDevice.FlashMode.on
            case "auto":
                flashModeAsEnum = AVCaptureDevice.FlashMode.auto
            default: break
            }
            if flashModeAsEnum != nil {
                try self.cameraController.setFlashMode(flashMode: flashModeAsEnum!)
            } else if flashMode == "torch" {
                try self.cameraController.setTorchMode()
            } else {
                call.reject("Flash Mode not supported")
                return
            }
            call.resolve()
        } catch {
            call.reject("failed to set flash mode")
        }
    }

    @objc func startRecordVideo(_ call: CAPPluginCall) {
        DispatchQueue.main.async {

            let quality: Int? = call.getInt("quality", 85)

            self.cameraController.captureVideo { (image, error) in

                guard let image = image else {
                    print(error ?? "Image capture error")
                    guard let error = error else {
                        call.reject("Image capture error")
                        return
                    }
                    call.reject(error.localizedDescription)
                    return
                }

                // self.videoUrl = image

                call.resolve(["value": image.absoluteString])
            }
        }
    }

    @objc func stopRecordVideo(_ call: CAPPluginCall) {

        self.cameraController.stopRecording { (_) in

        }
    }

    @objc func isCameraStarted(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.cameraController.captureSession?.isRunning ?? false {
                call.resolve(["value": true])
            } else {
                call.resolve(["value": false])
            }
        }
    }
    
    // MARK: - Overlay Methods
    @objc func showOverlay(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.overlayView == nil {
                self.setupOverlay()
            }
            self.overlayView?.isHidden = false
            call.resolve()
        }
    }
    
    @objc func hideOverlay(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.overlayView?.isHidden = true
            call.resolve()
        }
    }
    
    @objc func updateOverlayBorderColor(_ call: CAPPluginCall) {
        guard let colorString = call.getString("color") else {
            call.reject("Color parameter is required")
            return
        }
        
        DispatchQueue.main.async {
            let color = self.colorFromHex(colorString)
            self.overlayView?.updateBorderColor(color)
            call.resolve()
        }
    }
    
    @objc func updateOverlayText(_ call: CAPPluginCall) {
        guard let text = call.getString("text") else {
            call.reject("Text parameter is required")
            return
        }
        
        DispatchQueue.main.async {
            self.overlayView?.updateLabelText(text)
            call.resolve()
        }
    }
    
    @objc func startOverlayPulse(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.overlayView?.pulseAnimation()
            call.resolve()
        }
    }
    
    @objc func stopOverlayPulse(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.overlayView?.stopPulseAnimation()
            call.resolve()
        }
    }
    
    // MARK: - Private Overlay Methods
    private func setupOverlay() {
        guard let parentView = self.previewView?.superview else { return }
        
        self.overlayView = CameraOverlayView(frame: self.previewView.frame)
        guard let overlayView = self.overlayView else { return }
        
        parentView.addSubview(overlayView)
        
        // Configure overlay based on document type
        let documentType: CameraOverlayView.DocumentType
        switch self.overlayDocumentType {
        case "passport":
            documentType = .passport
        case "idCard":
            documentType = .idCard
        default:
            documentType = .idCard
        }
        
        overlayView.configureForDocument(
            documentType,
            in: overlayView.bounds,
            labelText: self.overlayLabelText
        )
        
        // Apply custom colors
        let borderColor = colorFromHex(self.overlayBorderColor)
        let backgroundColor = colorFromHex(self.overlayBackgroundColor)
        
        overlayView.updateBorderColor(borderColor)
        
        // Set up close button callback
        overlayView.onClosePressed = { [weak self] in
            self?.handleOverlayClose()
        }
        
        // Bring to front if not using toBack mode
        if !self.toBack! {
            parentView.bringSubviewToFront(overlayView)
        }
    }
    
    private func updateOverlayForCurrentOrientation() {
        guard let overlayView = self.overlayView else { return }
        
        let documentType: CameraOverlayView.DocumentType
        switch self.overlayDocumentType {
        case "passport":
            documentType = .passport
        case "idCard":
            documentType = .idCard
        default:
            documentType = .idCard
        }
        
        overlayView.configureForDocument(
            documentType,
            in: overlayView.bounds,
            labelText: self.overlayLabelText
        )
    }
    
    private func colorFromHex(_ hex: String) -> UIColor {
        var cString: String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        if cString.hasPrefix("#") {
            cString.remove(at: cString.startIndex)
        }
        
        var rgbValue: UInt64 = 0
        let length = cString.count
        
        if length == 6 || length == 8 {
            Scanner(string: cString).scanHexInt64(&rgbValue)
            
            if length == 6 {
                return UIColor(
                    red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
                    green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
                    blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
                    alpha: 1.0
                )
            } else {
                return UIColor(
                    red: CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0,
                    green: CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0,
                    blue: CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0,
                    alpha: CGFloat(rgbValue & 0x000000FF) / 255.0
                )
            }
        }
        
        return UIColor.white
    }
    
    // MARK: - Close Handler
    private func handleOverlayClose() {
        // Stop Vision processing first to prevent crashes
        cameraController.disableDataOutputDelegate()
        cameraController.stopVision()
        
        // Stop camera session immediately (use camera controller to handle threading)
        self.cameraController.stopCaptureSession()
        
        // Clean up UI elements on main thread if needed
        if Thread.isMainThread {
            self.previewView?.removeFromSuperview()
            self.overlayView?.removeFromSuperview()
            self.overlayView = nil
            self.webView?.isOpaque = true
        } else {
            DispatchQueue.main.sync {
                self.previewView?.removeFromSuperview()
                self.overlayView?.removeFromSuperview()
                self.overlayView = nil
                self.webView?.isOpaque = true
            }
        }
        
        // Notify JavaScript side that camera was closed
        self.notifyListeners("cameraClosedByUser", data: [:])
    }

}
extension CameraPreview: CameraTextRecognitionDelegate {
    func didRecognizeText(blocks: [[String: Any]]) {
        // Ensure notifyListeners is called on main thread for safety
        if Thread.isMainThread {
            self.notifyListeners("textRecognized", data: ["value": blocks])
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.notifyListeners("textRecognized", data: ["value": blocks])
            }
        }
        
        // Debug logging on background thread is fine
        print("Text recognition delegate called with \(blocks.count) blocks")
    }
}
