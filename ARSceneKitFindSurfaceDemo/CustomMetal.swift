import Foundation
import Metal
import MetalKit
import simd
import ARKit
import SceneKit

extension Float {
    static let degreesToRadian = Float.pi / 180
}

extension UIInterfaceOrientation {
    var cameraToDisplayRotation: Int {
        get {
            switch self {
            case .landscapeLeft:
                return 180
            case .portrait:
                return 90
            case .portraitUpsideDown:
                return -90
            default:
                return 0
            }
        }
    }
}

// Maximum size of point buffer
let maxPoints = 50_000
// Number of sample points on the grid
let numGridPointsMax = 25_000

class CustomMetal
{
    private let textureCache: CVMetalTextureCache!
    
    private let unprojectPipelineState: MTLRenderPipelineState!
    private let pointCloudPipelineState: MTLRenderPipelineState!
    private let relaxedStencilState: MTLDepthStencilState!
    
    private let unprojectUniformBuffer: MTLBuffer!
    private let unprojectPointCloudBuffer: MTLBuffer!
    private let pointCloudUniformBuffer: MTLBuffer!
    
    private var lastFrameTimestamp: TimeInterval = 0.0
    private var depthTexture: CVMetalTexture? = nil
    private var confidenceTexture: CVMetalTexture? = nil
    private var realSampleCount: Int = 0
    
    private var pointCloudCache: UnsafeMutablePointer<simd_float4>
    private var pointCountInCache: Int = 0
    
    private var _confidenceThreshold: ARConfidenceLevel = .low
    private var _pointCloudOpacity: Float = 0.25
    
    private var capturedImageTextureY: CVMetalTexture? = nil
    private var capturedImageTextureCbCr: CVMetalTexture? = nil
    
    private let _capturedImageMaterial: SCNMaterial
    private let _capturedImageYProperty: SCNMaterialProperty
    private let _capturedImageCbCrProperty: SCNMaterialProperty
    
    // MARK: - Properties
    
    public var confidenceThreshold: ARConfidenceLevel {
        get { return _confidenceThreshold }
        set(val) { _confidenceThreshold = val }
    }
    
    public var pointCloudOpacity: Float {
        get { return _pointCloudOpacity }
        set(val) { _pointCloudOpacity = max( 0.0, min( val, 1.0 ) ) }
    }
    
    public var capturedImageMaterial: SCNMaterial {
        get { return _capturedImageMaterial }
    }
    
    // MARK: - Initializers
    
    init(arView: ARSCNView)
    {
        let device = arView.device!
        
        // Create captured image texture cache
        var texCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &texCache)
        self.textureCache = texCache
        
        let defaultLibrary = device.makeDefaultLibrary()!
        let unprojectVertexFunction = defaultLibrary.makeFunction(name: "unprojectVertex")
        
        let unprojectPipelineStateDescriptor = MTLRenderPipelineDescriptor()
        unprojectPipelineStateDescriptor.vertexFunction = unprojectVertexFunction
        unprojectPipelineStateDescriptor.isRasterizationEnabled = false
        
        do {
            try unprojectPipelineState = device.makeRenderPipelineState(descriptor: unprojectPipelineStateDescriptor)
        }
        catch let error {
            fatalError("Failed to created unproject pipeline state, error \(error)")
        }
        
        let pointCloudVertexFunction = defaultLibrary.makeFunction(name: "pointCloudVertex")
        let pointCloudFragmentFunction = defaultLibrary.makeFunction(name: "pointCloudFragment")
        
        let pointCloudPipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pointCloudPipelineStateDescriptor.vertexFunction = pointCloudVertexFunction
        pointCloudPipelineStateDescriptor.fragmentFunction = pointCloudFragmentFunction
        pointCloudPipelineStateDescriptor.colorAttachments[0].pixelFormat = arView.colorPixelFormat
        pointCloudPipelineStateDescriptor.depthAttachmentPixelFormat = arView.depthPixelFormat
        
        do {
            try pointCloudPipelineState = device.makeRenderPipelineState(descriptor: pointCloudPipelineStateDescriptor)
        }
        catch let error {
            fatalError("Failed to created point cloud pipeline state, error \(error)")
        }
        
        // point cloud does not need to read/write depth
        let relaxedStateDescriptor = MTLDepthStencilDescriptor()
        relaxedStencilState = device.makeDepthStencilState(descriptor: relaxedStateDescriptor)
        
        // Buffers
        unprojectUniformBuffer = device.makeBuffer(length: MemoryLayout<UnprojectUniforms>.size, options: .storageModeShared)!
        unprojectPointCloudBuffer = device.makeBuffer(length: MemoryLayout<simd_float4>.stride * maxPoints, options: .storageModeShared)!
        pointCloudUniformBuffer = device.makeBuffer(length:MemoryLayout<PointCloudUniforms>.size, options: .storageModeShared)!
        
        pointCloudCache = UnsafeMutablePointer<simd_float4>.allocate(capacity: maxPoints)
        
        //
        // SCNMaterial
        //
        _capturedImageYProperty = SCNMaterialProperty()
        _capturedImageCbCrProperty = SCNMaterialProperty()
        
        _capturedImageMaterial = SCNMaterial()
        _capturedImageMaterial.setValue(_capturedImageYProperty, forKey: "capturedImageTextureY")
        _capturedImageMaterial.setValue(_capturedImageCbCrProperty, forKey: "capturedImageTextureCbCr")
        // NOTE: Our OBJ model's texture coordinate system is based on OpenGL texture coordinate system.
        //       -> Flip texture coordinate on y-direction.
        _capturedImageMaterial.shaderModifiers = [
            SCNShaderModifierEntryPoint.surface :
"""
#pragma arguments
texture2d<float, access::sample> capturedImageTextureY;
texture2d<float, access::sample> capturedImageTextureCbCr;

#pragma body
constexpr sampler colorSampler(mip_filter::linear, mag_filter::linear, min_filter::linear);

const float4x4 ycbcrToRGBTransform = float4x4(
  float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
  float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
  float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
  float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
);

// Flip Y
float2 texCoord = float2( _surface.diffuseTexcoord.x, 1.0f - _surface.diffuseTexcoord.y );

// Sample Y and CbCr textures to get the YCbCr color at the given texture coordinate
float4 ycbcr = float4(capturedImageTextureY.sample(colorSampler, texCoord).r,
                      capturedImageTextureCbCr.sample(colorSampler, texCoord).rg, 1.0);

// Convert to RGB
_surface.diffuse = ycbcrToRGBTransform * ycbcr;
"""
        ]
    }
    
    // MARK: - Methods
    
    func updateResources(frame: ARFrame, viewportSize: CGSize, orientation: UIInterfaceOrientation = .landscapeRight)
    {
        guard frame.timestamp != lastFrameTimestamp,
              let sceneDepth = frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap
        else { return }
        
        lastFrameTimestamp = frame.timestamp
        
        // MARK: - Update Captured Image Texture
        
        let pixelBuffer = frame.capturedImage
        if (CVPixelBufferGetPlaneCount(pixelBuffer) > 1 ) {
            capturedImageTextureY    = createTexture( fromPixelBuffer: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0 )
            capturedImageTextureCbCr = createTexture( fromPixelBuffer: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1 )
            
            if let textureY = capturedImageTextureY,
               let textureCbCr = capturedImageTextureCbCr
            {
                _capturedImageYProperty.contents = CVMetalTextureGetTexture(textureY)
                _capturedImageCbCrProperty.contents = CVMetalTextureGetTexture(textureCbCr)
            }
        }
        
        // MARK: - Update Depth Texture
        
        depthTexture = createTexture(fromPixelBuffer: sceneDepth.depthMap, pixelFormat: .r32Float)
        confidenceTexture = createTexture(fromPixelBuffer: confidenceMap, pixelFormat: .r8Uint)
        
        
        // MARK: - Update Unproject Uniforms
        
        let up_uniforms = unprojectUniformBuffer.contents().assumingMemoryBound(to: UnprojectUniforms.self)
        let camera = frame.camera
        
        let rotateToARCamera = matrix_float4x4( simd_float4(1, 0, 0, 0), simd_float4(0, -1, 0, 0), simd_float4(0, 0, -1, 0), simd_float4(0, 0, 0, 1) ) // FlipYZ
                             * matrix_float4x4( simd_quaternion( Float.degreesToRadian * Float(orientation.cameraToDisplayRotation), simd_float3(0, 0, 1)) )
        
        let cameraResolution = simd_float2( Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height) )
        
        let gridArea = cameraResolution.x * cameraResolution.y
        let spacing  = sqrt( gridArea / Float( numGridPointsMax ) )
        let deltaX   = Int32(round(cameraResolution.x / spacing))
        let deltaY   = Int32(round(cameraResolution.y / spacing))
        
        up_uniforms.pointee.localToWorld             = camera.viewMatrix(for: orientation).inverse * rotateToARCamera
        
        up_uniforms.pointee.cameraIntrinsicsInversed = camera.intrinsics.inverse
        up_uniforms.pointee.cameraResolution         = cameraResolution
        up_uniforms.pointee.gridResolution           = simd_int2( deltaX, deltaY )
        
        up_uniforms.pointee.spacing                  = spacing
        // maxPoints & index values use fixed value, if not accumulate point cloud
        up_uniforms.pointee.maxPoints                = Int32(maxPoints)
        up_uniforms.pointee.pointCloudCurrentIndex   = Int32(0)
        
        realSampleCount = Int(deltaX * deltaY)
        
        // MARK: - Update Point Cloud (rendering) Uniforms
        
        let pc_uniforms = pointCloudUniformBuffer.contents().assumingMemoryBound(to: PointCloudUniforms.self)
        
        pc_uniforms.pointee.viewMatrix = camera.viewMatrix(for: orientation)
        pc_uniforms.pointee.projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: viewportSize, zNear: 0.1, zFar: 200.0)
        pc_uniforms.pointee.confidenceThreshold = Int32(_confidenceThreshold.rawValue)
        pc_uniforms.pointee.opacity = _pointCloudOpacity
    }
    
    func unprojectPointCloud(commandEncoder: MTLRenderCommandEncoder)
    {
        guard let depthTexture = depthTexture,
              let confidenceTexture = confidenceTexture,
              realSampleCount > 0
        else { return }
        
        commandEncoder.pushDebugGroup("Unproject")
        
        commandEncoder.setRenderPipelineState(unprojectPipelineState)
        commandEncoder.setVertexBuffer(unprojectPointCloudBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(unprojectUniformBuffer, offset: 0, index: 1)
        commandEncoder.setVertexTexture(CVMetalTextureGetTexture(depthTexture), index: 0)
        commandEncoder.setVertexTexture(CVMetalTextureGetTexture(confidenceTexture), index: 1)
        
        commandEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: realSampleCount)
        
        commandEncoder.popDebugGroup()
    }
    
    func overlayPointCloud(commandEncoder: MTLRenderCommandEncoder)
    {
        guard realSampleCount > 0 else { return }
        
        commandEncoder.pushDebugGroup("PointCloud")
        
        commandEncoder.setRenderPipelineState(pointCloudPipelineState)
        commandEncoder.setDepthStencilState(relaxedStencilState)
        
        commandEncoder.setVertexBuffer(unprojectPointCloudBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(pointCloudUniformBuffer, offset: 0, index: 1)
        
        commandEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: realSampleCount)
        
        commandEncoder.popDebugGroup()
    }
    
    func copyPointCloudCache(withConfidenceThreshold threshold: ARConfidenceLevel = .high) -> (pointCloud: UnsafePointer<simd_float4>, pointCount: Int)? {
        guard realSampleCount > 0   else { return nil }
        
        var realCount = 0
        let src = unprojectPointCloudBuffer.contents().assumingMemoryBound(to: simd_float4.self)
        let dst = pointCloudCache
        for i in 0..<realSampleCount {
            if Int(src[i].w) < threshold.rawValue { continue }
            dst[realCount] = src[i]
            realCount += 1
        }
        
        if realCount > 0 {
            return ( UnsafePointer<simd_float4>( pointCloudCache ), realCount )
        }
        
        return nil
    }
    
    // MARK: - private
    
    private func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int = 0) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)
        
        if status != kCVReturnSuccess {
            texture = nil
        }
        
        return texture
    }
    
}
