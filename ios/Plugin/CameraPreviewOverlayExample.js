// CameraPreviewOverlayExample.js
// Example usage of the enhanced Camera Preview plugin with overlay support and close button

/**
 * Example: Start camera with ID card overlay (with updated dimensions)
 */
async function startCameraWithOverlay() {
  try {
    // Set up close event listener before starting camera
    CameraPreview.addListener('cameraClosedByUser', () => {
      console.log('Camera was closed by user using X button');
      // Handle cleanup or navigation back to your app here
      // For example, you might want to show a message or navigate to a different page
    });

    await CameraPreview.start({
      position: 'rear',
      width: window.innerWidth,
      height: window.innerHeight,
      x: 0,
      y: 0,
      toBack: false, // IMPORTANT: Set to false to show overlay on top
      showOverlay: true,
      overlayDocumentType: 'idCard', // Now with 15% more height and reduced padding
      overlayBorderColor: '#FFFFFF',
      overlayBackgroundColor: '#00000080', // 50% black overlay
      overlayLabelText: 'Place your ID card inside the frame'
    });

    console.log('Camera started with improved overlay');
  } catch (error) {
    console.error('Failed to start camera:', error);
  }
}

/**
 * Example: Setup all event listeners
 */
function setupCameraEventListeners() {
  // Listen for close button press
  CameraPreview.addListener('cameraClosedByUser', () => {
    console.log('User pressed close button - camera stopped');
    // Add your cleanup logic here
    handleCameraClosed();
  });

  // Listen for text recognition
  CameraPreview.addListener('textRecognized', (data) => {
    console.log('Text recognized:', data);
    const hasIdCardData = checkForIdCardData(data.value);
    updateOverlayForDetection(hasIdCardData);
  });
}

/**
 * Handle camera close event
 */
function handleCameraClosed() {
  // Clean up any timers or intervals
  // Navigate back to previous screen
  // Show message to user
  console.log('Cleaning up after camera close');

  // Example navigation (adjust for your framework)
  // window.history.back(); // For web
  // router.back(); // For Vue Router
  // navigateBack(); // For your custom navigation
}

/**
 * Example: Update overlay based on detection results (unchanged)
 */
async function updateOverlayForDetection(hasValidDocument) {
  try {
    if (hasValidDocument) {
      // Document detected - show green border and success message
      await CameraPreview.updateOverlayBorderColor('#00FF00');
      await CameraPreview.updateOverlayText('Document detected! Tap to capture');
      await CameraPreview.stopOverlayPulse();
    } else {
      // No valid document - show red border and guidance
      await CameraPreview.updateOverlayBorderColor('#FF0000');
      await CameraPreview.updateOverlayText('Please position your document properly');
      await CameraPreview.startOverlayPulse();
    }
  } catch (error) {
    console.error('Failed to update overlay:', error);
  }
}

/**
 * Complete workflow example for ID card scanning with close button
 */
async function idCardScanningWorkflowWithCloseButton() {
  try {
    // 1. Setup event listeners first
    setupCameraEventListeners();

    // 2. Start camera with improved overlay
    await startCameraWithOverlay();

    // 3. Simulate text recognition callback
    const simulateTextRecognition = () => {
      const hasIdCardData = Math.random() > 0.5; // Random for demo
      updateOverlayForDetection(hasIdCardData);

      // Continue checking every 2 seconds
      setTimeout(simulateTextRecognition, 2000);
    };

    // Start the recognition simulation
    simulateTextRecognition();

  } catch (error) {
    console.error('ID card scanning workflow failed:', error);
  }
}

/**
 * Programmatically stop camera (alternative to close button)
 */
async function stopCameraProgrammatically() {
  try {
    await CameraPreview.stop();
    console.log('Camera stopped programmatically');
  } catch (error) {
    console.error('Failed to stop camera:', error);
  }
}

/**
 * Helper function to check for ID card specific data (unchanged)
 */
function checkForIdCardData(textBlocks) {
  if (!textBlocks || textBlocks.length === 0) {
    return false;
  }

  // Look for typical ID card patterns
  const patterns = [
    /\b\d{2}\/\d{2}\/\d{4}\b/, // Date pattern
    /\b[A-Z]{2}\d{6,8}\b/,     // License number pattern
    /\bDOB\b/i,                // Date of birth
    /\bEXP\b/i,                // Expiration
    /\bSEX\b/i,                // Gender field
  ];

  for (const block of textBlocks) {
    const text = block.text || '';
    for (const pattern of patterns) {
      if (pattern.test(text)) {
        return true;
      }
    }
  }

  return false;
}

// Example usage in your app
document.addEventListener('DOMContentLoaded', () => {
  // Example button to start camera
  const startButton = document.getElementById('startCameraBtn');
  if (startButton) {
    startButton.onclick = idCardScanningWorkflowWithCloseButton;
  }

  // Example button to stop camera programmatically
  const stopButton = document.getElementById('stopCameraBtn');
  if (stopButton) {
    stopButton.onclick = stopCameraProgrammatically;
  }
});

// Export functions for use in your app
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    startCameraWithOverlay,
    setupCameraEventListeners,
    handleCameraClosed,
    updateOverlayForDetection,
    idCardScanningWorkflowWithCloseButton,
    stopCameraProgrammatically,
    checkForIdCardData
  };
}
