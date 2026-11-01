// Educational direct-light BRDF. All colors are linear RGB.
// Model: isotropic GGX D + Schlick F + height-correlated Smith G.
// This include is independent of Unity headers. See ../06_Unity_URP_Implementation.md.
#ifndef UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED
#define UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED

static const float CPBR_PI = 3.14159265358979323846;
static const float CPBR_MIN_ROUGHNESS = 0.045;
static const float CPBR_VISIBILITY_EPSILON = 1e-7;

struct CPBR_Material
{
    float3 baseColor;             // Linear reflectance, clamped to [0, 1].
    float metallic;               // [0, 1].
    float perceptualRoughness;    // r, NOT alpha. alpha = r*r.
};

float CPBR_Pow5(float x)
{
    float x2 = x * x;
    return x2 * x2 * x;
}

float3 CPBR_SafeNormalize(float3 value)
{
    // Zero directions remain zero; invalid lighting directions are rejected below.
    return value * rsqrt(max(dot(value, value), 1e-12));
}

float CPBR_RoughnessToAlpha(float perceptualRoughness)
{
    float r = clamp(perceptualRoughness, CPBR_MIN_ROUGHNESS, 1.0);
    return r * r;
}

float3 CPBR_F0(float3 baseColor, float metallic)
{
    return lerp(float3(0.04, 0.04, 0.04), saturate(baseColor), saturate(metallic));
}

float CPBR_DistributionGGX(float NoH, float alpha)
{
    NoH = saturate(NoH);
    alpha = clamp(alpha, CPBR_MIN_ROUGHNESS * CPBR_MIN_ROUGHNESS, 1.0);
    float alpha2 = alpha * alpha;
    float NoH2 = NoH * NoH;
    // Equivalent to NoH2*(alpha2-1)+1, with less cancellation at NoH=1.
    float d = (1.0 - NoH2) + NoH2 * alpha2;
    return alpha2 / (CPBR_PI * d * d);
}

float3 CPBR_FresnelSchlick(float VoH, float3 F0)
{
    return F0 + (1.0 - F0) * CPBR_Pow5(1.0 - saturate(VoH));
}

float CPBR_VisibilitySmithGGXCorrelated(float NoL, float NoV, float alpha)
{
    NoL = saturate(NoL);
    NoV = saturate(NoV);
    if (NoL <= 0.0 || NoV <= 0.0)
        return 0.0;

    alpha = clamp(alpha, CPBR_MIN_ROUGHNESS * CPBR_MIN_ROUGHNESS, 1.0);
    float alpha2 = alpha * alpha;
    float lambdaV = NoL * sqrt(NoV * NoV * (1.0 - alpha2) + alpha2);
    float lambdaL = NoV * sqrt(NoL * NoL * (1.0 - alpha2) + alpha2);
    // Returns G/(4*NoL*NoV), NOT G. The floor changes extreme grazing values.
    return 0.5 / max(lambdaV + lambdaL, CPBR_VISIBILITY_EPSILON);
}

float CPBR_GeometrySmithGGXCorrelated(float NoL, float NoV, float alpha)
{
    // For inspection / visualization; EvaluateBRDF uses visibility directly.
    return 4.0 * saturate(NoL) * saturate(NoV)
        * CPBR_VisibilitySmithGGXCorrelated(NoL, NoV, alpha);
}

void CPBR_EvaluateBRDF(
    CPBR_Material material, float3 normal, float3 viewDir, float3 lightDir,
    out float3 diffuseBRDF, out float3 specularBRDF)
{
    diffuseBRDF = float3(0.0, 0.0, 0.0);
    specularBRDF = float3(0.0, 0.0, 0.0);
    if (dot(normal, normal) < 1e-12 || dot(viewDir, viewDir) < 1e-12
        || dot(lightDir, lightDir) < 1e-12)
        return;

    // All three input directions must refer to the same coordinate space.
    float3 N = CPBR_SafeNormalize(normal);
    float3 V = CPBR_SafeNormalize(viewDir);   // Surface -> camera.
    float3 L = CPBR_SafeNormalize(lightDir);  // Surface -> light.
    float NoL = saturate(dot(N, L));
    float NoV = saturate(dot(N, V));
    if (NoL <= 0.0 || NoV <= 0.0)
        return;

    float3 halfVector = V + L;
    if (dot(halfVector, halfVector) < 1e-12)
        return;
    float3 H = CPBR_SafeNormalize(halfVector);
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));
    float3 baseColor = saturate(material.baseColor);
    float metallic = saturate(material.metallic);
    float alpha = CPBR_RoughnessToAlpha(material.perceptualRoughness);
    float3 F = CPBR_FresnelSchlick(VoH, CPBR_F0(baseColor, metallic));
    float D = CPBR_DistributionGGX(NoH, alpha);
    float visibility = CPBR_VisibilitySmithGGXCorrelated(NoL, NoV, alpha);

    specularBRDF = D * F * visibility; // Do not divide by 4*NoL*NoV again.
    float3 kD = (1.0 - F) * (1.0 - metallic);
    diffuseBRDF = kD * baseColor / CPBR_PI;
    // This diffuse/specular coupling is approximate; no multiple-scattering fix.
}

float3 CPBR_EvaluateDirect(
    CPBR_Material material, float3 normal, float3 viewDir, float3 lightDir,
    float3 lightColor, float distanceAttenuation, float shadowAttenuation)
{
    float3 diffuseBRDF;
    float3 specularBRDF;
    CPBR_EvaluateBRDF(material, normal, viewDir, lightDir, diffuseBRDF, specularBRDF);
    float NoL = saturate(dot(CPBR_SafeNormalize(normal), CPBR_SafeNormalize(lightDir)));
    // distanceAttenuation can exceed 1 for a nearby punctual light: do not saturate.
    float attenuation = max(distanceAttenuation, 0.0) * saturate(shadowAttenuation);
    return (diffuseBRDF + specularBRDF) * max(lightColor, 0.0) * NoL * attenuation;
    // HDR linear output. No AO, IBL, emission, tone mapping or gamma conversion.
}

#endif // UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED
