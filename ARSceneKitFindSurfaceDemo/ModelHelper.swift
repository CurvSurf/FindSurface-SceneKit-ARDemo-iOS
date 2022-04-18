import Foundation
import SceneKit
import SceneKit.ModelIO

func loadAssets() -> [String: SCNNode]
{
    let bundle = Bundle.main
    
    let assetURLs: [String: URL?] = [
        "ArrowBannerCeil" : bundle.url(forResource: "ArrowBannerCeil", withExtension: "obj", subdirectory: "models"),
        "ArrowBannerFloor" : bundle.url(forResource: "ArrowBannerFloor", withExtension: "obj", subdirectory: "models"),
        "CircularBanner" : bundle.url(forResource: "CircularBanner", withExtension: "obj", subdirectory: "models"),
        "MonitorBody" : bundle.url(forResource: "MonitorBody", withExtension: "obj", subdirectory: "models"),
        "MonitorScreen" : bundle.url(forResource: "MonitorScreen", withExtension: "obj", subdirectory: "models"),
        "SimpleCylinder" : bundle.url(forResource: "SimpleCylinder", withExtension: "obj", subdirectory: "models"),
        "StandBanner" : bundle.url(forResource: "StandBanner", withExtension: "obj", subdirectory: "models"),
    ]
    
    var models = [String:SCNNode]()
    for (assetName, assetURL) in assetURLs {
        if let assetURL = assetURL {
            let mdlAsset = MDLAsset(url: assetURL)
            mdlAsset.loadTextures()
            
            let mdlMesh = mdlAsset.childObjects(of: MDLMesh.self).first as! MDLMesh
            models[assetName] = SCNNode(mdlObject: mdlMesh)
        }
    }
    
    models["ArrowBannerCeil"]!.simdScale = simd_float3(repeating: 0.5)
    models["ArrowBannerFloor"]!.simdScale = simd_float3(repeating: 0.5)
    models["CircularBanner"]!.simdScale = simd_float3(repeating: 0.25)
    models["MonitorBody"]!.simdScale = simd_float3(repeating: 0.4)
    models["MonitorScreen"]!.simdScale = simd_float3(repeating: 0.4)
    models["StandBanner"]!.simdScale = simd_float3(repeating: 0.5)
    
    return models
}

func rotateAnimation(duration: Float) -> CABasicAnimation
{
    let ret = CABasicAnimation(keyPath: "rotation")
    ret.toValue = SCNVector4(0, -1, 0, Float.pi * 2.0)
    ret.duration = CFTimeInterval( duration )
    ret.repeatCount = Float.greatestFiniteMagnitude
    
    return ret
}
