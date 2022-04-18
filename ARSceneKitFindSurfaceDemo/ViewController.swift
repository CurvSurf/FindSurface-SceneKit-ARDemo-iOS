import UIKit
import SceneKit
import ARKit
import FindSurfaceFramework

let GAZE_POINT_ALPHA: Float = 0.5
let MIN_TOUCH_RADIUS_PIXEL: Float = 32.0
let MIN_PROBE_RADIUS_PIXEL: Float = 2.5
let orientation: UIInterfaceOrientation = .landscapeRight

class ViewController: UIViewController, ARSCNViewDelegate, SCNSceneRendererDelegate {

    @IBOutlet var sceneView: ARSCNView!
    let sceneKitRenderNode = SCNNode()
    
    // MARK: - UI Elements
    
    private let opacitySlider     = UISlider()
    private let confidenceControl = UISegmentedControl(items: ["C.Low", "C.Med", "C.High"])
    
    private let typeControl       = UISegmentedControl(items: [UIImage(named: "icon_plane")!,
                                                               UIImage(named: "icon_sphere")!,
                                                               UIImage(named: "icon_cylinder")!])
    
    private let actionButton      = UIButton()
    private let clearButton       = UIButton()
    
    private let gazePointView     = UIImageView(image: UIImage(named: "cube"))
    private let touchRadiusView   = UIView()
    private let probeRadiusView   = UIView()
    
    // LayoutConstraint
    private var touchRadiusWidthConstraint: NSLayoutConstraint? = nil
    private var touchRadiusHeightConstraint: NSLayoutConstraint? = nil
    private var probeRadiusWidthConstraint: NSLayoutConstraint? = nil
    private var probeRadiusHeightConstraint: NSLayoutConstraint? = nil
    
    // MARK: - Application Objects
    
    var customMetal: CustomMetal!
    var fsCtx: FindSurface!
    var fsTaskQueue = DispatchQueue(label:"FindSurfaceQueue", attributes: [], autoreleaseFrequency: .workItem)
    
    var models: [String: SCNNode]!
    
    // MARK: - Application Porperties
    
    var showPointCloud: Bool = true
    var findType: FindSurface.FeatureType = .plane
    var isFindSurfaceBusy: Bool = false
    var touchRadiusPixel: Float = 64.0  // Touch Radius Indicator View Radius in Pixel
    var probeRadiusPixel: Float = 10.0  // Probe Radius Indicator View Radius in Pixel
    
    // Calculated Property
    var MAX_VIEW_RADIUS: Float { get { return min( Float(self.view.bounds.width), Float(self.view.bounds.height) ) / 2.0 } }
    
    // MARK: - ViewController Methods
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        sceneView.delegate = self
        
        // Show statistics such as fps and timing information
        sceneView.showsStatistics = true
        
        // Create a new scene (empty)
        let scene = SCNScene()
        scene.rootNode.addChildNode(sceneKitRenderNode)
        
        // Set the scene to the view
        sceneView.scene = scene
        
        // Initialize custom metal object
        customMetal = CustomMetal(arView: sceneView)
        
        // Initialize application view(s)
        buildUI()
        
        // Load 3D models.
        models = loadAssets()
        
        // Register touch event(s)
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        sceneView.addGestureRecognizer(pinchGesture)
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        panGesture.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(panGesture)
        
        // Get FindSurface Instance
        fsCtx = FindSurface.sharedInstance()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [] // Disable Embeded Plane Detection
        configuration.frameSemantics = [ .sceneDepth ] // We will use sceneDepth

        // Run the view's session
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    
    // MARK: - UI Builder
    
    func buildUI()
    {
        // Confidence control
        confidenceControl.backgroundColor = .white
        confidenceControl.selectedSegmentIndex = customMetal.confidenceThreshold.rawValue
        confidenceControl.addTarget(self, action: #selector(confidenceValueChanged), for: .valueChanged)
        
        // Opacity slider
        opacitySlider.minimumValue = 0.0
        opacitySlider.maximumValue = 1.0
        opacitySlider.value = customMetal.pointCloudOpacity
        opacitySlider.maximumValueImage = UIImage(systemName: "eye")!
        opacitySlider.minimumValueImage = UIImage(systemName: "eye.slash")!
        opacitySlider.tintColor = .white
        opacitySlider.maximumTrackTintColor = .darkGray
        opacitySlider.minimumTrackTintColor = .systemBlue
        opacitySlider.addTarget(self, action: #selector(opacityValueChanged), for: .valueChanged)
        
        // FindType control
        typeControl.backgroundColor = .white
        typeControl.selectedSegmentIndex = 0
        typeControl.addTarget(self, action: #selector(typeValueChanged), for: .valueChanged)
        
        // Put 3 controls to StackView
        let stackView = UIStackView(arrangedSubviews: [typeControl, confidenceControl, opacitySlider])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 20
        
        // Action button
        actionButton.setImage(UIImage(named:"findBtn"), for: .normal)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addTarget(self, action: #selector(onClickActionButton), for: .touchUpInside)
        
        // Clear button
        clearButton.setImage(UIImage(named:"delete"), for: .normal)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.addTarget(self, action: #selector(onClickClearButton), for: .touchUpInside)
        
        // Gaze Point View
        gazePointView.isOpaque = true
        gazePointView.alpha    = CGFloat(GAZE_POINT_ALPHA * customMetal.pointCloudOpacity)
        gazePointView.translatesAutoresizingMaskIntoConstraints = false
        
        // TouchRadius Indicator View
        let _diameter = CGFloat(2.0 * touchRadiusPixel)
        touchRadiusView.translatesAutoresizingMaskIntoConstraints = false
        touchRadiusView.alpha = CGFloat(customMetal.pointCloudOpacity)
        touchRadiusView.layer.borderWidth = CGFloat(2.0)
        touchRadiusView.layer.borderColor = UIColor.white.cgColor
        touchRadiusView.layer.cornerRadius = CGFloat(touchRadiusPixel)
        //touchRadiusView.frame.size = CGSize(width: _diameter, height: _diameter)
        
        // ProbeRadius Indicator View
        let _diameter2 = CGFloat(2.0 * probeRadiusPixel)
        probeRadiusView.translatesAutoresizingMaskIntoConstraints = false
        probeRadiusView.alpha = CGFloat(customMetal.pointCloudOpacity)
        probeRadiusView.layer.borderWidth = CGFloat(2.0)
        probeRadiusView.layer.borderColor = UIColor.red.cgColor
        probeRadiusView.layer.cornerRadius = CGFloat(probeRadiusPixel)
        
        // Add View(s)
        sceneView.addSubview(gazePointView)
        sceneView.addSubview(touchRadiusView)
        sceneView.addSubview(probeRadiusView)
        sceneView.addSubview(stackView)
        sceneView.addSubview(actionButton)
        sceneView.addSubview(clearButton)
        
        touchRadiusWidthConstraint  = touchRadiusView.widthAnchor.constraint(equalToConstant: _diameter)
        touchRadiusHeightConstraint = touchRadiusView.heightAnchor.constraint(equalToConstant: _diameter)
        probeRadiusWidthConstraint  = probeRadiusView.widthAnchor.constraint(equalToConstant: _diameter2)
        probeRadiusHeightConstraint = probeRadiusView.heightAnchor.constraint(equalToConstant: _diameter2)
        
        // Set Layout
        NSLayoutConstraint.activate([
            // Stack View
            stackView.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            stackView.bottomAnchor.constraint(equalTo: sceneView.bottomAnchor, constant: -32),
            // Opacity Slider
            opacitySlider.widthAnchor.constraint(equalTo: sceneView.widthAnchor, multiplier: 0.25),
            // Action Button
            actionButton.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            actionButton.rightAnchor.constraint(equalTo: sceneView.rightAnchor, constant: -16),
            actionButton.widthAnchor.constraint(equalToConstant: CGFloat(64)),
            actionButton.heightAnchor.constraint(equalToConstant: CGFloat(64)),
            // Clear Button
            clearButton.topAnchor.constraint(equalTo: actionButton.bottomAnchor),
            clearButton.rightAnchor.constraint(equalTo: sceneView.rightAnchor, constant: -12),
            clearButton.widthAnchor.constraint(equalToConstant: CGFloat(40)),
            clearButton.heightAnchor.constraint(equalToConstant: CGFloat(40)),
            // Gaze Point View
            gazePointView.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            gazePointView.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            // Touch Radius Indicator View
            touchRadiusView.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            touchRadiusView.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            touchRadiusWidthConstraint!,
            touchRadiusHeightConstraint!,
            // Probe Radius Indicator View
            probeRadiusView.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            probeRadiusView.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            probeRadiusWidthConstraint!,
            probeRadiusHeightConstraint!,
        ])
    }
    
    // MARK: - Update View Property
    
    func updateTouchRadiusView() {
        let td = CGFloat( 2.0 * touchRadiusPixel )
        touchRadiusView.layer.cornerRadius = CGFloat(touchRadiusPixel)
        
        touchRadiusWidthConstraint!.constant = td
        touchRadiusHeightConstraint!.constant = td
    }
    
    func updateProbeRadiusView() {
        let pd = CGFloat( 2.0 * probeRadiusPixel )
        probeRadiusView.layer.cornerRadius = CGFloat(probeRadiusPixel)
        
        probeRadiusWidthConstraint!.constant = pd
        probeRadiusHeightConstraint!.constant = pd
    }

    // MARK: - ARSCNViewDelegate
    
/*
    // Override to create and configure nodes for anchors added to the view's session.
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        let node = SCNNode()
     
        return node
    }
*/
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
    }
    
    // MARK: - SCNSceneRendererDelegate
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let session = sceneView.session
        guard let frame = session.currentFrame else { return }

        // Update resources (uniforms, etc) before scene render loop
        customMetal.updateResources(frame: frame, viewportSize: renderer.currentViewport.size)
    }

    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let commandEncoder = renderer.currentRenderCommandEncoder else { return }
        
        // Unproject point cloud just before scene rendering
        customMetal.unprojectPointCloud(commandEncoder: commandEncoder)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard showPointCloud,
              let commandEncoder = renderer.currentRenderCommandEncoder
        else { return }
        
        // Draw point cloud after scene redering (overlay)
        customMetal.overlayPointCloud(commandEncoder: commandEncoder)
    }
    
    // MARK: - Touch Event
    
    @objc
    func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            let velocity = Float(gesture.velocity)
            
            let factor: Float = 10
            
            touchRadiusPixel = simd_clamp( touchRadiusPixel + (velocity * factor), MIN_TOUCH_RADIUS_PIXEL, MAX_VIEW_RADIUS )
            if probeRadiusPixel > touchRadiusPixel {
                probeRadiusPixel = touchRadiusPixel
            }
            
            // Update to view
            updateTouchRadiusView()
            updateProbeRadiusView()
        }
    }
    
    @objc
    func handlePan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .changed {
            let velocity = gesture.velocity(in: view)
            
            let factor: Float = 0.01
            probeRadiusPixel = simd_clamp( probeRadiusPixel + (Float(velocity.y) * factor), MIN_PROBE_RADIUS_PIXEL, touchRadiusPixel )
            
            // Update to view
            updateProbeRadiusView()
        }
    }
    
    // MARK: - UI Event(s)
    
    @objc
    private func confidenceValueChanged(_: UIView)
    {
        switch confidenceControl.selectedSegmentIndex
        {
        case 0:
            customMetal.confidenceThreshold = .low
        case 1:
            customMetal.confidenceThreshold = .medium
        case 2:
            customMetal.confidenceThreshold = .high
        default: // never reach here
            break
        }
    }
    
    @objc
    private func opacityValueChanged(_: UIView)
    {
        customMetal.pointCloudOpacity = opacitySlider.value
        showPointCloud = opacitySlider.value > 0.0
        
        gazePointView.alpha = CGFloat( GAZE_POINT_ALPHA * opacitySlider.value )
        touchRadiusView.alpha = CGFloat( opacitySlider.value )
        probeRadiusView.alpha = CGFloat( opacitySlider.value )
    }
    
    @objc
    private func typeValueChanged(_: UIView)
    {
        switch typeControl.selectedSegmentIndex
        {
        case 0:
            findType = .plane
        case 1:
            findType = .sphere
        case 2:
            findType = .cylinder
        default: // never reach here
            break
        }
    }
    
    @objc
    private func onClickActionButton(_: UIView)
    {
        // MARK: - Run FindSurface Here!!
        
        guard !isFindSurfaceBusy,
              let camera = sceneView.session.currentFrame?.camera,
              let pointCloudCache = customMetal.copyPointCloudCache()
        else { return }
        
        let viewSize = sceneView.currentViewport.size
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: viewSize, zNear: 0.1, zFar: 200.0)
        
        let scaleFactor = viewSize.width < viewSize.height ? projectionMatrix.columns.0.x : projectionMatrix.columns.1.y
        let touchRadius = (touchRadiusPixel / MAX_VIEW_RADIUS) / scaleFactor
        let probeRadius = (probeRadiusPixel / MAX_VIEW_RADIUS) / scaleFactor
        
        let cameraTransform  = camera.transform // Right-Handed
        let rayDirection     = -simd_make_float3( cameraTransform.columns.2 )
        let rayOrigin        =  simd_make_float3( cameraTransform.columns.3 )
        let targetType       = findType
        
        isFindSurfaceBusy = true
        fsTaskQueue.async
        {
            let pickIdx = pickPoint(rayDirection: rayDirection, rayPosition: rayOrigin, vertices: pointCloudCache.pointCloud, count: pointCloudCache.pointCount, probeRadius)
            if pickIdx >= 0
            {
                let pickPoint = simd_make_float3( pointCloudCache.pointCloud[pickIdx] )
                let distance  = abs( simd_dot( (pickPoint - rayOrigin), rayDirection ) )
                let scaledTouchRadius = touchRadius * distance
                
                self.fsCtx.measurementAccuracy = 0.02 // error is allowed up to 2 cm
                self.fsCtx.meanDistance        = 0.2  // up to 20 cm
                
                self.fsCtx.setPointCloudData( UnsafeRawPointer( pointCloudCache.pointCloud ),
                                              pointCount: pointCloudCache.pointCount,
                                              pointStride: MemoryLayout<simd_float4>.stride,
                                              useDoublePrecision: false )
                
                do {
                    if let result = try self.fsCtx.findSurface(featureType: targetType, seedIndex: pickIdx, seedRadius: scaledTouchRadius, requestInlierFlags: false)
                    {
                        if let planeParam = result.getAsPlaneResult()
                        {
                            let param = planeParam.getARParam(withCameraTransform: cameraTransform)
                            let UP = simd_make_float3(0, 1, 0)
                            
                            let det = simd_dot(UP, param.normal)
                            let absDet = abs(det)
                            
                            if absDet < 0.15 { // horizontal normal -> Vertical Wall (error less than 9 degree )
                                let right = simd_normalize( simd_cross( UP, param.normal ) )
                                let front = simd_normalize( simd_cross( right, UP ) )
                                
                                let orientation = simd_quaternion(simd_float3x3(right, UP, front))
                                let position = param.hitPoint!
                                
                                let monitorBody = self.models["MonitorBody"]!.clone()
                                let monitorScreen = self.models["MonitorScreen"]!.clone()
                                
                                monitorBody.simdOrientation = orientation
                                monitorBody.simdPosition = position
                                
                                monitorScreen.simdOrientation = orientation
                                monitorScreen.simdPosition = position
                                if let geometry = monitorScreen.geometry {
                                    geometry.firstMaterial = self.customMetal.capturedImageMaterial
                                }
                                
                                DispatchQueue.main.async {
                                    self.sceneKitRenderNode.addChildNode(monitorBody)
                                    self.sceneKitRenderNode.addChildNode(monitorScreen)
                                }
                            }
                            else if absDet > 0.99 { // vertical normal -> Floor or Ceil (error less than 8 degree )
                                let model = det > 0
                                          ? self.models["StandBanner"]!.clone()    // Floor
                                          : self.models["CircularBanner"]!.clone() // Ceil
                                
                                let right = simd_normalize( simd_cross( UP, simd_make_float3(cameraTransform.columns.2) ) )
                                let front = simd_normalize( simd_cross( right, UP ) ) // toward to camera
                                
                                model.simdOrientation = simd_quaternion( simd_float3x3( right, UP, front ) )
                                model.simdPosition    = param.hitPoint!
                                
                                DispatchQueue.main.async {
                                    self.sceneKitRenderNode.addChildNode(model)
                                }
                            }
                            else { // slope
                                let model = det > 0
                                          ? self.models["ArrowBannerFloor"]!.clone() // Floor Slope
                                          : self.models["ArrowBannerCeil"]!.clone()  // Ceil Slope
                                
                                let normal = det > 0 ? param.normal : -param.normal
                                
                                let right = simd_normalize( simd_cross( normal, UP ) )
                                let front = simd_normalize( simd_cross( right, normal ) )
                                
                                model.simdOrientation = simd_quaternion( simd_float3x3( right, normal, front ) )
                                model.simdPosition    = param.hitPoint!
                                
                                DispatchQueue.main.async {
                                    self.sceneKitRenderNode.addChildNode(model)
                                }
                            }
                        }
                        else if let sphereParam = result.getAsSphereResult()
                        {
                            let param  = sphereParam.getARParam(withCameraTransform: cameraTransform, andSeedPoint: pickPoint, orientationType: .roundingSurface)
                            
                            if param.isConvex {
                                let transformNode = SCNNode()
                                transformNode.simdPosition = sphereParam.center
                                transformNode.simdScale    = simd_float3(repeating: sphereParam.radius)
                                
                                if let _ = param.hitPoint,
                                   let orientation = param.hitPointOrientation
                                {
                                    transformNode.simdOrientation = orientation
                                }
                                else {
                                    transformNode.simdOrientation = simd_quaternion(cameraTransform)
                                }
                                
                                let modelNode = self.models["SimpleCylinder"]!.clone()
                                modelNode.addAnimation(rotateAnimation(duration: 5.0), forKey: nil)
                                
                                transformNode.addChildNode(modelNode)
                                
                                DispatchQueue.main.async {
                                    self.sceneKitRenderNode.addChildNode(transformNode)
                                }
                            }
                            else {
                                // ignore at this sample
                            }
                        }
                        else if let cylinderParam = result.getAsCylinderResult()
                        {
                            let param = cylinderParam.getARParam(withCameraTransform: cameraTransform, andSeedPoint: pickPoint, orientationType: .roundingSurface)
                            
                            if let _ = param.hitPoint,
                               let axisPoint = param.axisPoint,
                               let orientation = param.hitPointOrientation
                            {
                                if param.isConvex {
                                    
                                    let transformNode = SCNNode()
                                    transformNode.simdPosition    = axisPoint
                                    transformNode.simdOrientation = orientation
                                    transformNode.simdScale       = simd_float3(repeating: cylinderParam.radius)
                                    
                                    let modelNode = self.models["SimpleCylinder"]!.clone()
                                    modelNode.addAnimation(rotateAnimation(duration: 5.0), forKey: nil)
                                    
                                    transformNode.addChildNode(modelNode)
                                    
                                    DispatchQueue.main.async {
                                        self.sceneKitRenderNode.addChildNode(transformNode)
                                    }
                                }
                                else {
                                    // ignore at this sample
                                }
                            }
                        }
                    }
                    else {
                        print("Not Found")
                    }
                }
                catch let error {
                    print("FindSurfaceError: \(error)")
                }
            }
            DispatchQueue.main.async {
                self.isFindSurfaceBusy = false
            }
        }
    }
    
    @objc
    func onClickClearButton(_: UIView)
    {
        sceneKitRenderNode.enumerateChildNodes{ (node, stop) in
            node.removeFromParentNode()
        }
    }
}
