#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Structure shared between shader and C code to ensure the layout of instance uniform data accessed in
//    Metal shaders matches the layout of uniform data set in C code
typedef struct {
    matrix_float4x4 localToWorld;
    matrix_float3x3 cameraIntrinsicsInversed;
    simd_float2 cameraResolution;
    simd_int2   gridResolution;
    
    float spacing;
    int maxPoints;
    int pointCloudCurrentIndex;
} UnprojectUniforms;

typedef struct {
    matrix_float4x4 viewMatrix;
    matrix_float4x4 projectionMatrix;
    // Point Cloud Confidence
    int confidenceThreshold;
    float opacity;
} PointCloudUniforms;

#endif /* ShaderTypes_h */
