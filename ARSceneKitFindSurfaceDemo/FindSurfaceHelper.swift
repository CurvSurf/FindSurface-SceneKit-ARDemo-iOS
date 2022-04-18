import Foundation
import simd
import FindSurfaceFramework

func pickPoint(rayDirection ray_dir: simd_float3, rayPosition ray_pos: simd_float3, vertices list: UnsafePointer<simd_float4>, count: Int, _ unitRadius: Float) -> Int {
    let UR_SQ_PLUS_ONE = unitRadius * unitRadius + 1.0
    var minLen: Float = Float.greatestFiniteMagnitude
    var maxCos: Float = -Float.greatestFiniteMagnitude
    
    var pickIdx   : Int = -1
    var pickIdxExt: Int = -1
    
    for idx in 0..<count {
        let sub = simd_make_float3(list[idx]) - ray_pos
        let len1 = simd_dot( ray_dir, sub )
        
        if len1 < Float.ulpOfOne { continue; } // Float.ulpOfOne == FLT_EPSILON
        // 1. Inside ProbeRadius (Picking Cylinder Radius)
        if simd_length_squared(sub) < UR_SQ_PLUS_ONE * (len1 * len1) {
            if len1 < minLen { // find most close point to camera (in z-direction distance)
                minLen = len1
                pickIdx = idx
            }
        }
        // 2. Outside ProbeRadius
        else {
            let cosine = len1 / simd_length(sub)
            if cosine > maxCos { // find most close point to probe radius
                maxCos = cosine
                pickIdxExt = idx
            }
        }
    }
    
    return pickIdx < 0 ? pickIdxExt : pickIdx
}

public enum OrientationType
{
    case roundingSurface
    case onSurface
}

extension FindPlaneResult
{
    func getARParam(withCameraTransform t: matrix_float4x4) -> (normal: simd_float3, hitPoint: simd_float3?)
    {
        let ll = lowerLeft
        let lr = lowerRight
        let ur = upperRight
        let ul = upperLeft
        
        let xAxis = simd_normalize( ur - ul )
        let zAxis = simd_normalize( ll - ul )
        
        let yAxis = simd_normalize( simd_cross( zAxis, xAxis ) )
        
        let origin = (ll + lr + ur + ul) / 4.0
        
        let lookAt = -simd_make_float3(t.columns.2)
        let from   = simd_make_float3(t.columns.3)
        let det    = simd_dot( yAxis, lookAt )
        
        // Flip a plane's normal vector if the normal vector does not forward to our camera
        let normal = det < 0 ? yAxis : -yAxis
        
        // case parallel (generally, never reach here)
        if abs(det) < 0.1 { return (normal, nil) }
        
        let t = simd_dot(origin - from, normal) / simd_dot(lookAt, normal)
        let hitPoint   = t * lookAt + from
        
        return (normal, hitPoint)
    }
}

extension FindSphereResult
{
    func getARParam(withCameraTransform t: matrix_float4x4, andSeedPoint point: simd_float3, orientationType type: OrientationType) -> (isConvex: Bool, hitPoint: simd_float3?, hitPointOrientation: simd_quatf?)
    {
        let sphereCenter = center
        let cameraPosition = simd_make_float3(t.columns.3)
        let cameraDirection = -simd_make_float3(t.columns.2)
        let cameraUpDirection = simd_make_float3(t.columns.1)
        
        // Test is sphere convex or not
        let cameraToSeedPoint = simd_normalize( point - cameraPosition )
        let centerToSeedPoint = simd_normalize( point - sphereCenter )

        let isConvex = simd_dot( cameraToSeedPoint, centerToSeedPoint ) < 0
        
        // Find actual hit point
        let K = cameraPosition - sphereCenter
        
        let a = simd_dot(cameraDirection, cameraDirection)
        let b = simd_dot( K, cameraDirection )
        let c = simd_dot( K, K ) - (radius * radius)
        
        let det = (b * b) - (a * c)
        
        if det < 0 { // generally, never reach here
            return (isConvex, nil, nil)
        }
        else if det == 0 {
            let t = -b / a
            
            let hitPoint = cameraDirection * t + cameraPosition
            
            let front = simd_normalize( hitPoint - center )
            let right = simd_normalize( simd_cross( cameraUpDirection, front ) )
            let up = simd_normalize( simd_cross( front, right ) )
            
            var orientation: simd_quatf
            switch type
            {
            case .roundingSurface:
                orientation = simd_quaternion( simd_float3x3( right, up, front ) )
            case .onSurface:
                orientation = simd_quaternion( simd_float3x3( up, front, right ) )
                // orientation = simd_quaternion( simd_float3x3( right, front, -up ) )
                // orientation = simd_quaternion( simd_float3x3( -up, front, -right ) )
            }
            
            return (isConvex, hitPoint, orientation)
        }
        else // det > 0
        {
            let sqrtDet = sqrt(det)
            
            let t1 = (-b + sqrtDet) / a
            let t2 = (-b - sqrtDet) / a
            
            let p1 = cameraDirection * t1 + cameraPosition
            let p2 = cameraDirection * t2 + cameraPosition
            
            // Find closest point from seed point
            let hitPoint = simd_distance_squared(p1, point) < simd_distance_squared(p2, point) ? p1 : p2
            
            let front = simd_normalize( hitPoint - center )
            let right = simd_normalize( simd_cross( cameraUpDirection, front ) )
            let up = simd_normalize( simd_cross( front, right ) )
            
            var orientation: simd_quatf
            switch type
            {
            case .roundingSurface:
                orientation = simd_quaternion( simd_float3x3( right, up, front ) )
            case .onSurface:
                orientation = simd_quaternion( simd_float3x3( up, front, right ) )
                // orientation = simd_quaternion( simd_float3x3( right, front, -up ) )
                // orientation = simd_quaternion( simd_float3x3( -up, front, -right ) )
            }
            
            return (isConvex, hitPoint, orientation)
        }
    }
}

extension FindCylinderResult
{
    func getARParam(withCameraTransform ct: matrix_float4x4, andSeedPoint point: simd_float3, orientationType type: OrientationType) -> (axis: simd_float3, isConvex: Bool, hitPoint: simd_float3?, axisPoint: simd_float3?, hitPointOrientation: simd_quatf? )
    {
        let t = top
        let b = bottom
        
        let cameraYAxis = simd_make_float3( ct.columns.1 )
        let cameraZAxis = simd_make_float3( ct.columns.2 )
        let cameraPosition = simd_make_float3( ct.columns.3 )
        
        let yAxis = simd_normalize( t - b )
        
        let axis = simd_dot(yAxis, cameraYAxis) < 0 ? -yAxis : yAxis
        
//        let xAxis = simd_normalize( simd_cross( axis, cameraZAxis ) )
//        let zAxis = simd_normalize( simd_cross( xAxis, axis ) )
        
        // Test is cylinder convex or not
        let cameraToSeedPoint = simd_normalize( point - cameraPosition )
        let bottomToSeedPoint = simd_normalize( point - b )
        //let axisToSeedPoint = simd_normalize( axis * simd_dot(bottomToSeedPoint, axis) + bottomToSeedPoint )
        
        let isConvex = simd_dot( cameraToSeedPoint, bottomToSeedPoint ) < 0
        
        let tmp = cameraPosition - b
        let lookAt = -cameraZAxis
        
        let dn = simd_dot(lookAt, axis)
        let tn = simd_dot(tmp, axis)
        
        let A = simd_dot(lookAt, lookAt) - dn * dn
        let B = simd_dot(tmp, lookAt) - (simd_dot(tmp, axis) * dn)
        let C = simd_dot(tmp, tmp) - (tn * tn) - (radius * radius)
        
        let det = (B * B) - (A * C)
        if det < 0 {
            return (axis, isConvex, nil, nil, nil)
        }
        else if det == 0 {
            let k = -B / A
            let hitPoint = k * lookAt + cameraPosition
            let axisPoint = simd_dot( hitPoint - b, axis ) * axis + b
            
            let front = simd_normalize( hitPoint - axisPoint )
            let right = simd_normalize( simd_cross( axis, front ) )
            
            var orientation: simd_quatf
            switch type
            {
            case .roundingSurface:
                orientation = simd_quaternion( simd_float3x3( right, axis, front ) )
            case .onSurface:
                orientation = simd_quaternion( simd_float3x3( axis, front, right ) )
                // orientation = simd_quaternion( simd_float3x3( right, front, -axis ) )
            }
            
            return (axis, isConvex, hitPoint, axisPoint, orientation)
        }
        else {
            let sqrtDet = sqrt(det)
            
            let k1 = (-B + sqrtDet) / A
            let k2 = (-B - sqrtDet) / A
            
            let p1 = k1 * lookAt + cameraPosition
            let p2 = k2 * lookAt + cameraPosition
            
            // Find closest point from seed point
            let hitPoint = simd_distance_squared(p1, point) < simd_distance_squared(p2, point) ? p1 : p2
            let axisPoint = simd_dot( hitPoint - b, axis ) * axis + b
            
            let front = simd_normalize( hitPoint - axisPoint )
            let right = simd_normalize( simd_cross( axis, front ) )
            
            var orientation: simd_quatf
            switch type
            {
            case .roundingSurface:
                orientation = simd_quaternion( simd_float3x3( right, axis, front ) )
            case .onSurface:
                orientation = simd_quaternion( simd_float3x3( axis, front, right ) )
                // orientation = simd_quaternion( simd_float3x3( right, front, -axis ) )
            }
            
            return (axis, isConvex, hitPoint, axisPoint, orientation)
        }
    }
}
