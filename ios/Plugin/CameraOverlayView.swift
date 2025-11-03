//
//  CameraOverlayView.swift
//  Plugin
//
//  Created for ID Card scanning overlay functionality
//

import UIKit
import AVFoundation

class CameraOverlayView: UIView {
    
    // MARK: - Properties
    private var cutoutRect: CGRect = CGRect.zero
    private var overlayColor: UIColor = UIColor.black.withAlphaComponent(0.5)
    private var borderColor: UIColor = UIColor.white
    private var borderWidth: CGFloat = 2.0
    private var cornerRadius: CGFloat = 8.0
    private var labelText: String = ""
    private var labelBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.6)
    private var labelTextColor: UIColor = UIColor.white
    
    // UI Elements
    private var instructionLabel: UILabel?
    private var borderLayer: CAShapeLayer?
    private var closeButton: UIButton?
    
    // Callback for close button
    var onClosePressed: (() -> Void)?
    
    // MARK: - Initialization
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        backgroundColor = UIColor.clear
        isUserInteractionEnabled = true // Changed to true to allow close button interaction
    }
    
    // MARK: - Configuration Methods
    func configure(
        cutoutRect: CGRect,
        overlayColor: UIColor = UIColor.black.withAlphaComponent(0.5),
        borderColor: UIColor = UIColor.white,
        borderWidth: CGFloat = 2.0,
        cornerRadius: CGFloat = 8.0,
        labelText: String = "",
        labelBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.6),
        labelTextColor: UIColor = UIColor.white
    ) {
        self.cutoutRect = cutoutRect
        self.overlayColor = overlayColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.labelText = labelText
        self.labelBackgroundColor = labelBackgroundColor
        self.labelTextColor = labelTextColor
        
        updateOverlay()
    }
    
    func updateCutoutRect(_ rect: CGRect) {
        self.cutoutRect = rect
        updateOverlay()
    }
    
    func updateBorderColor(_ color: UIColor) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateBorderColor(color)
            }
            return
        }
        
        self.borderColor = color
        self.borderLayer?.strokeColor = color.cgColor
    }
    
    func updateLabelText(_ text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateLabelText(text)
            }
            return
        }
        
        self.labelText = text
        self.instructionLabel?.text = text
    }
    
    // MARK: - Private Methods
    private func updateOverlay() {
        // Ensure this runs on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateOverlay()
            }
            return
        }
        
        // Stop any existing animations first
        layer.removeAllAnimations()
        borderLayer?.removeAllAnimations()
        
        // Remove existing sublayers and subviews safely
        layer.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        subviews.forEach { view in
            view.removeFromSuperview()
        }
        
        // Reset references
        borderLayer = nil
        instructionLabel = nil
        closeButton = nil
        
        // Create the overlay with cutout
        createOverlayWithCutout()
        
        // Create border around cutout
        createBorder()
        
        // Create instruction label if text is provided
        if !labelText.isEmpty {
            createInstructionLabel()
        }
        
        // Create close button
        createCloseButton()
        
        setNeedsDisplay()
    }
    
    private func createOverlayWithCutout() {
        let overlayLayer = CAShapeLayer()
        let path = UIBezierPath(rect: bounds)
        
        // Create cutout path with rounded corners
        let cutoutPath = UIBezierPath(
            roundedRect: cutoutRect,
            cornerRadius: cornerRadius
        )
        
        // Subtract cutout from overlay
        path.append(cutoutPath.reversing())
        
        overlayLayer.path = path.cgPath
        overlayLayer.fillColor = overlayColor.cgColor
        overlayLayer.fillRule = .evenOdd
        
        layer.addSublayer(overlayLayer)
    }
    
    private func createBorder() {
        borderLayer = CAShapeLayer()
        let borderPath = UIBezierPath(
            roundedRect: cutoutRect,
            cornerRadius: cornerRadius
        )
        
        borderLayer?.path = borderPath.cgPath
        borderLayer?.strokeColor = borderColor.cgColor
        borderLayer?.fillColor = UIColor.clear.cgColor
        borderLayer?.lineWidth = borderWidth
        
        if let borderLayer = borderLayer {
            layer.addSublayer(borderLayer)
        }
    }
    
    private func createInstructionLabel() {
        instructionLabel = UILabel()
        guard let label = instructionLabel else { return }
        
        label.text = labelText
        label.textColor = labelTextColor
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.numberOfLines = 0
        
        // Create background view for label
        let backgroundView = UIView()
        backgroundView.backgroundColor = labelBackgroundColor
        backgroundView.layer.cornerRadius = 20
        backgroundView.layer.masksToBounds = true
        
        // Add backdrop blur effect
        let blurEffect = UIBlurEffect(style: .dark)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.layer.cornerRadius = 20
        blurEffectView.layer.masksToBounds = true
        
        addSubview(backgroundView)
        backgroundView.addSubview(blurEffectView)
        backgroundView.addSubview(label)
        
        // Setup constraints
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Position label above the cutout rectangle
        NSLayoutConstraint.activate([
            // Background view constraints
            backgroundView.centerXAnchor.constraint(equalTo: centerXAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: topAnchor, constant: cutoutRect.minY - 20),
            backgroundView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            backgroundView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            
            // Blur effect view constraints
            blurEffectView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            blurEffectView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
            
            // Label constraints
            label.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -12)
        ])
    }
    
    private func createCloseButton() {
        closeButton = UIButton(type: .custom)
        guard let button = closeButton else { return }
        
        // Create X icon
        button.setTitle("✕", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .medium)
        
        // Create circular background
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 20
        button.layer.masksToBounds = true
        
        // Add blur effect
        let blurEffect = UIBlurEffect(style: .dark)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.layer.cornerRadius = 20
        blurEffectView.layer.masksToBounds = true
        blurEffectView.isUserInteractionEnabled = false
        
        addSubview(blurEffectView)
        addSubview(button)
        
        // Setup constraints
        blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // Button constraints (top-right corner)
            button.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
            
            // Blur effect constraints
            blurEffectView.topAnchor.constraint(equalTo: button.topAnchor),
            blurEffectView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        
        // Add target action
        button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    }
    
    @objc private func closeButtonTapped() {
        // Ensure we're on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.closeButtonTapped()
            }
            return
        }
        
        // Call the closure safely
        onClosePressed?()
    }
    
    // MARK: - Cleanup
    deinit {
        print("CameraOverlayView deinitializing - cleaning up resources")
        
        // Clean up animations and remove observers
        layer.removeAllAnimations()
        borderLayer?.removeAllAnimations()
        
        // Remove all sublayers
        layer.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        
        // Clear callback to prevent retain cycles
        onClosePressed = nil
        
        // Remove all subviews
        subviews.forEach { $0.removeFromSuperview() }
        
        // Clear references
        borderLayer = nil
        instructionLabel = nil
        closeButton = nil
    }
    
    // MARK: - Animation Methods
    func animateBorderColor(to color: UIColor, duration: TimeInterval = 0.3) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.animateBorderColor(to: color, duration: duration)
            }
            return
        }
        
        guard let borderLayer = self.borderLayer else { return }
        
        // Remove existing animation first
        borderLayer.removeAnimation(forKey: "borderColorAnimation")
        
        let colorAnimation = CABasicAnimation(keyPath: "strokeColor")
        colorAnimation.fromValue = borderLayer.strokeColor
        colorAnimation.toValue = color.cgColor
        colorAnimation.duration = duration
        colorAnimation.fillMode = .forwards
        colorAnimation.isRemovedOnCompletion = false
        
        borderLayer.add(colorAnimation, forKey: "borderColorAnimation")
        borderLayer.strokeColor = color.cgColor
        self.borderColor = color
    }
    
    func pulseAnimation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.pulseAnimation()
            }
            return
        }
        
        guard let borderLayer = self.borderLayer else { return }
        
        // Remove existing pulse animation first
        borderLayer.removeAnimation(forKey: "pulseAnimation")
        
        let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 1.05
        pulseAnimation.duration = 0.6
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        
        borderLayer.add(pulseAnimation, forKey: "pulseAnimation")
    }
    
    func stopPulseAnimation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stopPulseAnimation()
            }
            return
        }
        
        self.borderLayer?.removeAnimation(forKey: "pulseAnimation")
    }
    
    // MARK: - Helper Methods
    func calculateIdCardRect(in bounds: CGRect) -> CGRect {
        // Standard ID card aspect ratio is approximately 1.586:1 (85.60 × 53.98 mm)
        let aspectRatio: CGFloat = 1.586
        let padding: CGFloat = 20 // Reduced from 40 to 20 (half)
        
        let availableWidth = bounds.width - (padding * 2)
        let availableHeight = bounds.height * 0.4 // Use 40% of screen height max
        
        var width = availableWidth
        var height = width / aspectRatio
        
        // Increase height by 15%
        height = height * 1.15
        
        if height > availableHeight {
            height = availableHeight
            width = height * aspectRatio / 1.15 // Adjust width to maintain aspect ratio
        }
        
        let x = (bounds.width - width) / 2
        let y = (bounds.height - height) / 2
        
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Overlay Configuration Extensions
extension CameraOverlayView {
    
    enum DocumentType {
        case idCard
        case passport
        case custom(CGRect)
        
        func rect(in bounds: CGRect) -> CGRect {
            switch self {
            case .idCard:
                // Call static method instead of creating new instance
                let aspectRatio: CGFloat = 1.586
                let padding: CGFloat = 20
                
                let availableWidth = bounds.width - (padding * 2)
                let availableHeight = bounds.height * 0.4
                
                var width = availableWidth
                var height = width / aspectRatio
                
                // Increase height by 15%
                height = height * 1.15
                
                if height > availableHeight {
                    height = availableHeight
                    width = height * aspectRatio / 1.15
                }
                
                let x = (bounds.width - width) / 2
                let y = (bounds.height - height) / 2
                
                return CGRect(x: x, y: y, width: width, height: height)
            case .passport:
                // Call static method instead of creating new instance
                let aspectRatio: CGFloat = 1.384
                let padding: CGFloat = 30
                
                let availableWidth = bounds.width - (padding * 2)
                let availableHeight = bounds.height * 0.5
                
                var width = availableWidth
                var height = width / aspectRatio
                
                if height > availableHeight {
                    height = availableHeight
                    width = height * aspectRatio
                }
                
                let x = (bounds.width - width) / 2
                let y = (bounds.height - height) / 2
                
                return CGRect(x: x, y: y, width: width, height: height)
            case .custom(let rect):
                return rect
            }
        }
    }
    
    func configureForDocument(_ documentType: DocumentType, in bounds: CGRect, labelText: String = "") {
        let rect = documentType.rect(in: bounds)
        configure(
            cutoutRect: rect,
            overlayColor: UIColor.black.withAlphaComponent(0.5),
            borderColor: UIColor.white,
            borderWidth: 2.0,
            cornerRadius: 8.0,
            labelText: labelText
        )
    }
}
