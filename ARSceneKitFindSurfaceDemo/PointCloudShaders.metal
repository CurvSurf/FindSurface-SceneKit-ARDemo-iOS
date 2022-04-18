#include <metal_stdlib>

// Include header shared between this Metal shader code and C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;
#include <SceneKit/scn_metal>

// MARK: - Unproject Point Cloud

// Unproject Point Cloud Vertex Function
///  Vertex shader that takes in a 2D grid-point and infers its 3D position in world-space, along with confidence
vertex void unprojectVertex(uint vertexID [[vertex_id]],
                            device float4 *pointCloudOutput [[buffer(0)]],
                            constant UnprojectUniforms &uniforms [[buffer(1)]],
                            texture2d<float, access::sample> depthTexture [[texture(0)]],
                            texture2d<unsigned int, access::sample> confidenceTexture [[texture(1)]])
{
    constexpr sampler basicSampler(mip_filter::linear, mag_filter::linear, min_filter::linear);
    
    const auto gridX = vertexID % uniforms.gridResolution.x;
    const auto gridY = vertexID / uniforms.gridResolution.x;
    
    const auto alternatingOffsetX = uniforms.spacing > 1.0f
                                  ? (gridY % 2) * uniforms.spacing / 2.0f
                                  : 0.0f;
    
    const auto cameraPoint = float2(
        alternatingOffsetX + (static_cast<float>(gridX) + 0.5f) * uniforms.spacing,
                             (static_cast<float>(gridY) + 0.5f) * uniforms.spacing
    );
    
    const auto currentPointIndex = (uniforms.pointCloudCurrentIndex + vertexID) % uniforms.maxPoints;
    const auto texCoord = cameraPoint / uniforms.cameraResolution;
    
    // Sample the depth map to get the depth value.
    const auto depth = depthTexture.sample(basicSampler, texCoord).r;
    
    // Sample the confidence map to get the confidence value.
    const auto confidence = confidenceTexture.sample(basicSampler, texCoord).r;
    
    // With a 2D point plus depth, we can now get its 3D position.
    const auto localPoint = uniforms.cameraIntrinsicsInversed * simd_float3( cameraPoint, 1 ) * depth;
    const auto worldPoint = uniforms.localToWorld * simd_float4( localPoint, 1 );
    const auto position   = worldPoint / worldPoint.w;
    
    // write the data to the buffer
    pointCloudOutput[currentPointIndex] = float4( position.xyz, static_cast<float>(confidence));
}

// MARK: - Render Point Cloud

// Point Cloud Vertex Shader outputs and Fragment shader inputs
struct PointCloudVertexOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

static constant float3 CONFIDENCE_COLOR[] = {
    float3( 1.0, 0.0, 0.0 ), // Red (Low)
    float3( 0.0, 0.0, 1.0 ), // Blue (Middle)
    float3( 0.0, 1.0, 0.0 )  // Green (High)
};

vertex PointCloudVertexOut pointCloudVertex(uint vertexID [[vertex_id]],
                                            constant float4 *pointCloudBuffer [[buffer(0)]],
                                            constant PointCloudUniforms &uniforms [[buffer(1)]])
{
    const auto pointData  = pointCloudBuffer[vertexID];
    const int  confidence = clamp( static_cast<int>( pointData.w ), 0, 2 );
    
    float4 cameraBasedPoisition = uniforms.viewMatrix * float4( pointData.xyz, 1 );
    float4 projectedPosition    = uniforms.projectionMatrix * cameraBasedPoisition;
    
    float distanceRatio = clamp( abs(cameraBasedPoisition.z), 0.0, 2.0 ) / 2.0; // max distance: 2 meter
    
    // prepare for output
    PointCloudVertexOut out;
    out.position  = projectedPosition;
    out.pointSize = mix( 10.0, 5.0, distanceRatio );
    out.color     = float4( CONFIDENCE_COLOR[ confidence ], uniforms.opacity );
    
    if( confidence < uniforms.confidenceThreshold ) {
        out.color.a = 0.0;
    }
    
    return out;
}

fragment float4 pointCloudFragment(PointCloudVertexOut in [[stage_in]], const float2 coords [[point_coord]]) {
    // we draw within a circle
    const float distSquared = length_squared(coords - float2(0.5));
    if (in.color.a == 0 || distSquared > 0.25) {
        discard_fragment();
    }
    
    return in.color;
}
