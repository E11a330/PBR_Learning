// 手写实现：下方依次给出参数转换、D、F、G、visibility、BRDF 与单灯组合的完整函数体。
// 所有颜色按线性 RGB 计算；这里使用 GGX D + Schlick F + 高度相关 Smith G。
// 本文件不依赖 Unity 头文件；完整接线见 ../06_Unity_URP_Implementation.md。
// 阅读顺序：材质参数 → alpha/F0 → 几何点乘 → D/F/visibility → BRDF → 单灯贡献。
// 03 中 ExplainDirectPBR 将下面的函数逐步展开；06 负责接入 Unity 几何与灯光。
#ifndef UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED
#define UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED

static const float CPBR_PI = 3.14159265358979323846;
static const float CPBR_MIN_ROUGHNESS = 0.045;
static const float CPBR_VISIBILITY_EPSILON = 1e-7;

struct CPBR_Material
{
    float3 baseColor;             // 线性颜色，在函数内夹到 [0,1]。
    float metallic;               // 0=非金属，1=金属。
    float perceptualRoughness;    // 面板上的粗糙度 r；不要预先平方。
};

float3 CPBR_SafeNormalize(float3 value)
{
    // 防止零向量归一化出错；光照入口还会拒绝无效方向。
    return value * rsqrt(max(dot(value, value), 1e-12));
}

float CPBR_RoughnessToAlpha(float perceptualRoughness)
{
    // 面板/纹理存储 r；D 与 G/V 接收 alpha=r²，内部才计算 alpha²。
    float r = clamp(perceptualRoughness, CPBR_MIN_ROUGHNESS, 1.0);
    return r * r;
}

float3 CPBR_F0(float3 baseColor, float metallic)
{
    float3 color = saturate(baseColor);
    float m = saturate(metallic);
    // F0=(1-m)*0.04+m*baseColor，每个颜色通道独立计算。
    return (1.0 - m) * float3(0.04, 0.04, 0.04) + m * color;
}

float CPBR_DistributionGGX(float NoH, float alpha)
{
    // D：法线分布密度。它可以大于 1，不要 saturate 返回值。
    NoH = saturate(NoH);
    alpha = clamp(alpha, CPBR_MIN_ROUGHNESS * CPBR_MIN_ROUGHNESS, 1.0);
    float alpha2 = alpha * alpha;
    float NoH2 = NoH * NoH;
    // 与常见 GGX 分母等价，NoH 接近 1 时减少精度损失。
    float d = (1.0 - NoH2) + NoH2 * alpha2;
    return alpha2 / (CPBR_PI * d * d);
}

float3 CPBR_FresnelSchlick(float VoH, float3 F0)
{
    // F：直接微表面反射使用 V·H；F0 与返回值均是 RGB。
    float x = 1.0 - saturate(VoH);
    float x2 = x * x;
    float x5 = x2 * x2 * x;
    // F=F0+(1-F0)*(1-VoH)^5。
    return F0 + (1.0 - F0) * x5;
}

float CPBR_VisibilitySmithGGXCorrelated(float NoL, float NoV, float alpha)
{
    // visibility 已包含 Cook–Torrance 分母；与纯 G 的数值范围不同。
    NoL = saturate(NoL);
    NoV = saturate(NoV);
    if (NoL <= 0.0 || NoV <= 0.0)
        return 0.0;

    alpha = clamp(alpha, CPBR_MIN_ROUGHNESS * CPBR_MIN_ROUGHNESS, 1.0);
    float alpha2 = alpha * alpha;
    float lambdaV = NoL * sqrt(NoV * NoV * (1.0 - alpha2) + alpha2);
    float lambdaL = NoV * sqrt(NoL * NoL * (1.0 - alpha2) + alpha2);
    // 返回 G/(4*NoL*NoV)，不是纯 G；极小分母下限会影响极端掠射值。
    return 0.5 / max(lambdaV + lambdaL, CPBR_VISIBILITY_EPSILON);
}

float CPBR_GeometrySmithGGXCorrelated(float NoL, float NoV, float alpha)
{
    // 独立实现 G，不通过调用 visibility 再反推。
    NoL = saturate(NoL);
    NoV = saturate(NoV);
    if (NoL <= 0.0 || NoV <= 0.0)
        return 0.0;
    alpha = clamp(alpha, CPBR_MIN_ROUGHNESS * CPBR_MIN_ROUGHNESS, 1.0);
    float alpha2 = alpha * alpha;
    float rootV = sqrt(NoV * NoV * (1.0 - alpha2) + alpha2);
    float rootL = sqrt(NoL * NoL * (1.0 - alpha2) + alpha2);
    float denominator = NoL * rootV + NoV * rootL;
    // G=2*NoL*NoV/denominator，等价于高度相关 Smith 的 Lambda 形式。
    // 与 visibility 使用同一分母下限，使两种组合在极端角度保持同一近似。
    return (2.0 * NoL * NoV) / max(denominator, CPBR_VISIBILITY_EPSILON);
}

void CPBR_EvaluateBRDF(
    CPBR_Material material, float3 normal, float3 viewDir, float3 lightDir,
    out float3 diffuseBRDF, out float3 specularBRDF)
{
    // 这一层只返回材质 BRDF，不乘当前灯光、阴影或外层 NoL。
    diffuseBRDF = float3(0.0, 0.0, 0.0);
    specularBRDF = float3(0.0, 0.0, 0.0);
    if (dot(normal, normal) < 1e-12 || dot(viewDir, viewDir) < 1e-12
        || dot(lightDir, lightDir) < 1e-12)
        return;

    // 三个方向必须在同一空间。本例接线统一用世界空间。
    float3 N = CPBR_SafeNormalize(normal);
    float3 V = CPBR_SafeNormalize(viewDir);   // 表面 → 相机。
    float3 L = CPBR_SafeNormalize(lightDir);  // 表面 → 光源。
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

    specularBRDF = D * F * visibility; // 不要再除一次 4*NoL*NoV。
    float3 kD = (1.0 - F) * (1.0 - metallic);
    diffuseBRDF = kD * baseColor / CPBR_PI;
    // 这是便于学习的能量分配近似，没有补微表面多次反射损失。
}

float3 CPBR_EvaluateDirect(
    CPBR_Material material, float3 normal, float3 viewDir, float3 lightDir,
    float3 lightColor, float distanceAttenuation, float shadowAttenuation)
{
    // 这一层应用渲染方程：对单盏灯乘光色、NoL 与场景衰减。
    float3 diffuseBRDF;
    float3 specularBRDF;
    CPBR_EvaluateBRDF(material, normal, viewDir, lightDir, diffuseBRDF, specularBRDF);
    float NoL = saturate(dot(CPBR_SafeNormalize(normal), CPBR_SafeNormalize(lightDir)));
    // 近处点光源的衰减值可能大于 1；只夹负值，不要 saturate。
    float attenuation = max(distanceAttenuation, 0.0) * saturate(shadowAttenuation);
    return (diffuseBRDF + specularBRDF) * max(lightColor, 0.0) * NoL * attenuation;
    // 返回线性 HDR。AO、环境反射、自发光和显示处理不在这里做。
}

#endif // UNITY_TA_NOTES_CUSTOM_PBR_INCLUDED
