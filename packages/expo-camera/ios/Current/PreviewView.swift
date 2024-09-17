import UIKit
import AVFoundation

class PreviewView: UIView {
  var videoPreviewLayer: AVCaptureVideoPreviewLayer {
    let previewLayer: AVCaptureVideoPreviewLayer? = {
      if Thread.current.isMainThread {
        return layer as? AVCaptureVideoPreviewLayer
      } else {
        return DispatchQueue.main.sync {
          return layer as? AVCaptureVideoPreviewLayer
        }
      }
    }()
    
    guard let thePreviewLayer = previewLayer else {
      fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check PreviewView.layerClass implementation.")
    }
    
    return thePreviewLayer
  }

  var session: AVCaptureSession? {
    get {
      return videoPreviewLayer.session
    }
    set {
      videoPreviewLayer.session = newValue
    }
  }

  override class var layerClass: AnyClass {
    return AVCaptureVideoPreviewLayer.self
  }
}
