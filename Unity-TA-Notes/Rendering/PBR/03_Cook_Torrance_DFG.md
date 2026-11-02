# 03 · Cook–Torrance 镜面 BRDF：D / F / G

[返回目录](README.md) · [上一篇](02_BRDF_Models.md) · [下一篇：材质参数](04_Material_Parameters.md)

## 总公式与符号

对于 `NoL > 0`、`NoV > 0` 的反射方向：

$$
f_s(L,V)=\frac{D(N,H,\alpha)\,F(V,H,F_0)\,G(N,L,V,\alpha)}{4(NoL)(NoV)}
$$

| 项 | 直观问题 | 类型 |
| --- | --- | --- |
| D | 有多少微表面恰好朝向 H？ | 标量分布密度，可大于 1 |
| F | 这些微表面反射多少光？ | RGB 反射比例 |
| G | 光能到达微表面，并且反射能被相机看到吗？ | 0～1 的几何因子 |
| `4 NoL NoV` | 微表面反射转换到宏观 BRDF 的几何归一化 | 分母 |

本篇固定采用 **各向同性 GGX D、Schlick F、高度相关 Smith G**。这是配套代码的模型定义，避免混用不同教程的近似。

## 1. 粗糙度先统一

$$r=1-s,\qquad \alpha=r^2,\qquad a^2=\alpha^2=r^4$$

`s` 是感知光滑度，`r` 是感知粗糙度。HLSL 变量 `alpha` 对应公式 `α`，`alpha2` 对应 `α²`。有些资料直接把 `α` 叫 roughness，因此看到平方时先核对定义。

示例：`r=0.5 → α=0.25 → α²=0.0625`。把 `r²` 当成 `α²` 会显著改变高光。

## 2. D：GGX 法线分布

$$
D_{GGX}=\frac{\alpha^2}{\pi\left[NoH^2(\alpha^2-1)+1\right]^2}
$$

粗糙度低，法线更集中，高光窄而峰值高；粗糙度高，分布更分散。粗糙度不只是给高光乘一个亮度系数。

分布的归一化条件为：

$$\int_{\Omega^+}D(H)(N\cdot H)\,d\omega_H=1$$

因此 `D` 不是「0～1 的概率」。代码将分母中的括号记为 d，并改写成 `d=(1-NoH²)+NoH²*alpha²`。两者代数等价，后者可减轻 `NoH≈1` 时的消减误差。

准确地说，D 描述单位宏观投影面积对应的微表面法线面积密度，方向域单位为 `sr⁻¹`。普通 NDF 采样时，归一化的方向 PDF 是 `p_H(H)=D(H)·max(N·H,0)`，不是 D 本身；可见法线采样（VNDF）又使用另一种 PDF。这个区别会影响后续 IBL 采样权重。

配套实现将 `r` 限制到 `[0.045,1]`，避免完美镜面极限。**不要**再把 `d*d` 粗暴夹到 `1e-4`，否则低粗糙度高光会被压坏。精确镜面需要 delta 分布处理，不靠将粗糙度设为 0 实现。

## 3. F：Schlick Fresnel

$$F=F_0+(1-F_0)(1-VoH)^5$$

`F0` 是正入射反射率。掠射时，Schlick 的这个版本趋近于 `F90=1`。

金属度工作流的近似：

$$F_0=\operatorname{lerp}(0.04,\;baseColor,\;metallic)$$

非金属的 `0.04` 是常用默认值，不是所有材质的常数。空气到非吸收介质，正入射有：

$$F_0=\left(\frac{\eta-1}{\eta+1}\right)^2$$

这里 `η=η_t/η_i` 为两侧折射率之比；空气近似 `η_i=1`，透射侧介质 `η_t=1.5` 时，得到 `F0=0.04`。金属涉及复折射率，本代码用 RGB F0 作近似，并不求解完整导体 Fresnel。

实现中用连乘得到五次方，最后的代码会对应这一项。


直接微表面镜面项使用 `VoH`。IBL 的近似或查表常以 `NoV` 为输入，那是经过方向积分后的另一层问题。

## 4. G：Smith 微表面遮蔽

为了区分两种常被混用的形式，先定义 GGX 的辅助函数（`x>0`）：

$$\Lambda(x)=\frac{\sqrt{1+\alpha^2(1-x^2)/x^2}-1}{2}$$

独立遮蔽假设：

$$G_{uncorrelated}=G_1(NoL)G_1(NoV),\quad G_1(x)=\frac{1}{1+\Lambda(x)}$$

本代码采用高度相关形式：

$$G_{correlated}=\frac{1}{1+\Lambda(NoL)+\Lambda(NoV)}$$

两者并不相等。高度相关形式考虑光线和视线对微表面可见性的关联；具体假设可查 [PBRT 的 masking-shadowing 章节](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory#sec:masking-shadowing-function)。

G 描述的是亚像素微几何遮蔽，**不是** Shadow Map，也不是 AO。实时场景阴影在最终单光源计算时另乘。

## 5. 为什么代码中出现 V，而不是 G

定义可见性项（这里 V 是函数名，与观察向量 `V` 按上下文区分）：

$$V_{Smith}=\frac{G}{4NoLNoV}$$

相关 Smith–GGX 可化简为：

$$
V_{Smith}=\frac{0.5}{
NoL\sqrt{NoV^2(1-\alpha^2)+\alpha^2}
+NoV\sqrt{NoL^2(1-\alpha^2)+\alpha^2}}
$$

于是：

$$f_s=D\,F\,V_{Smith}$$

**已经乘了 V，就不要再除 `4 NoL NoV`。** 配套函数 `CPBR_VisibilitySmithGGXCorrelated` 返回 V；调试函数 `CPBR_GeometrySmithGGXCorrelated` 才返回 G。

为避免极端掠射下分母接近零，V 的实现给分母加下限 `1e-7`；这是数值保护，会影响极端角度的精确值。进入函数前仍须拒绝 `NoL≤0` 或 `NoV≤0`。

下面的 G 函数独立实现 `G=2*NoL*NoV/q`，其中 q 就是上式 V 的分母。G 与 V 都对 q 使用同一数值下限，因此在保护生效的极端角度也采用同一近似；常规角度下与 Lambda 形式等价。

## 6. Schlick–GGX 的 k 是另一种近似

你还可能看到：

$$G_1(x)\approx\frac{x}{x(1-k)+k}$$

部分实时教程对直接光采用 `k=(r+1)²/8`，对 IBL 近似采用 `k=r²/2`。这些是特定约定下的拟合选择，不是 GGX 的通用恒等式。配套代码采用上面的相关 Smith 形式，**没有 k，也不应再叠加一次 Schlick G**。

## 7. 加上漫反射，再接灯光

本例使用便于理解的近似分配：

$$k_D=(1-F)(1-m),\quad f_d=k_D\frac{baseColor}{\pi}$$

$$C_{direct}=(f_d+f_s)\,C_{light}\,NoL\,A_{distance}\,A_{shadow}$$

纯金属 `m=1` 时，漫反射为 0。`(1-F)` 不要再乘到镜面项上。这个简化组合不能代替完整分层 BSDF；高粗糙度金属可能因漏算微表面多次散射而变暗。

## 8. 手算检查点

令 `N=L=V=(0,0,1)`、`r=0.5`、`metallic=0`、`baseColor=(1,1,1)`：

```text
alpha = 0.25, alpha2 = 0.0625
D = 16/pi ≈ 5.092958
F = 0.04
G = 1, Vsmith = 0.25
fs = 0.16/pi ≈ 0.050930
fd = 0.96/pi ≈ 0.305577
fd + fs = 1.12/pi ≈ 0.356507
```

灯光和两种衰减均为 1 时，直接光输出每通道约 `0.356507`。这只是单方向检查，不是半球能量积分。

## 9. 方向与粗糙度如何改变结果

固定 `N=V=(0,0,1)`，让 L 与 N 的夹角 θ 变化；白色非金属 `baseColor=1`、`r=0.5`，灯色与衰减均为 1。下表每个值都是线性值：

| θ | NoL | NoH = VoH | D | F | G | visibility | 单通道直接光 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0° | 1.000000 | 1.000000 | 5.092958 | 0.040000 | 1.000000 | 0.250000 | 0.356507 |
| 30° | 0.866025 | 0.965926 | 1.267138 | 0.040000 | 0.994845 | 0.287187 | 0.277244 |
| 60° | 0.500000 | 0.866025 | 0.225727 | 0.040041 | 0.957064 | 0.478532 | 0.154945 |
| 80° | 0.173648 | 0.766044 | 0.098308 | 0.040673 | 0.731262 | 1.052793 | 0.053757 |

如何读这张表：光源转离正面后，H 也离开 N，高光中心的 D 明显下降；NoL 又减小，所以直接光整体变暗。F 在这组方向中并没有接近 1，因为微表面入射角由 VoH 决定，不能把宏观 NoL 很小直接等同于 Fresnel 必然接近 1。

还可以看到 visibility 在 80° 时大于 1，但 G 仍小于 1。原因是 visibility 已除以 `4 NoL NoV`；把它误认成「应在 0～1 之间的 G」再夹到 1，会改变模型。

固定 `N=L=V`，只改变粗糙度则有：

$$D(NoH=1)=\frac{1}{\pi\alpha^2}=\frac{1}{\pi r^4}$$

`r=0.5` 时峰值约 `5.093`；`r=0.25` 时峰值约 `81.487`，提升 16 倍。这说明低粗糙度需要足够精度，也说明高光峰值不能直接用 `saturate(D)` 截掉。峰值更高并不意味着半球总能量按同样比例增加。

## 10. 公式与代码的对应

| 公式中的量 | 源码变量 / 函数 | 什么时候计算 |
| --- | --- | --- |
| r | `material.perceptualRoughness` | 材质采样后 |
| α | `CPBR_RoughnessToAlpha(r)` | 本可每片元一次；教学库为独立接口在调用内计算 |
| F0 | `CPBR_F0(baseColor, metallic)` | 与灯无关 |
| H | `CPBR_SafeNormalize(V + L)` | 每盏灯不同 |
| D | `CPBR_DistributionGGX(NoH, alpha)` | 每盏灯求值 |
| F | `CPBR_FresnelSchlick(VoH, F0)` | 每盏灯求值 |
| G/(4 NoL NoV) | `CPBR_VisibilitySmithGGXCorrelated(...)` | 每盏灯求值 |
| fr | `diffuseBRDF + specularBRDF` | 尚未乘光源 |
| 单灯积分贡献 | `CPBR_EvaluateDirect(...)` | 已乘 NoL、光色和衰减 |

后续要优化性能，可以把 α、F0 等与光无关的量移出灯光循环。但第一次实现时，优先保留函数边界，方便逐项检查。

## 11. 容易混淆的几组概念

| 概念 | 区别与代码影响 |
| --- | --- |
| D 与最终高光 | D 只描述方向分布，还要乘 F、G/V 与灯光 |
| G 与场景阴影 | G 是微表面遮蔽；Shadow Map 描述其他几何挡光 |
| G 与 visibility | 后者已除以 `4 NoL NoV`，不可重复除分母 |
| NoV 与 VoH | 直接微表面 Fresnel 用 VoH；IBL 拟合常以 NoV 为输入 |
| 粗糙度 r 与 alpha | 本文 alpha=r²；函数参数名必须看具体约定 |
| BRDF 与单灯颜色 | 后者还要乘光色、NoL、距离衰减和场景可见性 |

## 12. 对应 HLSL：把每个函数实现出来

前面是公式，下面直接给出完整函数体。`CPBR_` 是本笔记自写函数的前缀，不是 Unity 内置 BRDF；它们的定义全部在本节可见。

### 12.1 D、F、G 和组合函数的完整实现

阅读时先找三个函数：`CPBR_DistributionGGX` 的分子分母对应 D，`CPBR_FresnelSchlick` 的五次方对应 F，`CPBR_GeometrySmithGGXCorrelated` 的两个根号与几何分母对应 G。G 的独立实现没有调用 V 再反推。

`CPBR_VisibilitySmithGGXCorrelated` 是同一个 G 与分母合并后的实现；它与 G 是可选的两种求值形式。组合函数使用 V 的形式，避免极端角度下先乘除很小的量。

这段代码就是 `Shaders/CustomPBR.hlsl` 的完整内容，仅依赖 `dot/sqrt/rsqrt/saturate` 等 HLSL 基础指令。后半段调用的所有自写函数，都已经在前半段定义。

```hlsl
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
```

### 12.2 完全展开的单光源计算

下面进一步把参数转换、D、F、相关 Smith、Lambert 和单灯组合直接写进函数体。它不调用前面的 BRDF 辅助函数，只使用上面已经定义的 `CPBR_Material` 数据结构；数学指令均为 HLSL 内置指令。

这里的 `0.5/q` 是从 `G/(4NoLNoV)` 代数约简得到的，G 的完整独立函数已在 12.1 给出。若需要单独显示 G，使用它的函数体计算即可；正式镜面项不再重复乘 G 或重复除分母。

```hlsl
float3 ExplainDirectPBR(
    CPBR_Material material,
    float3 normalWS, float3 viewDirWS, float3 lightDirWS,
    float3 lightColor, float distanceAttenuation, float shadowAttenuation)
{
    // 1. 方向检查和归一化：这里只用 HLSL 数学指令。
    float n2 = dot(normalWS, normalWS);
    float v2 = dot(viewDirWS, viewDirWS);
    float l2 = dot(lightDirWS, lightDirWS);
    if (n2 < 1e-12 || v2 < 1e-12 || l2 < 1e-12)
        return float3(0, 0, 0);
    float3 N = normalWS * rsqrt(max(n2, 1e-12));
    float3 V = viewDirWS * rsqrt(max(v2, 1e-12));
    float3 L = lightDirWS * rsqrt(max(l2, 1e-12));
    float NoL = saturate(dot(N, L));
    float NoV = saturate(dot(N, V));
    if (NoL <= 0.0 || NoV <= 0.0)
        return float3(0, 0, 0);
    float3 sumVL = V + L;
    float h2 = dot(sumVL, sumVL);
    if (h2 < 1e-12)
        return float3(0, 0, 0);
    float3 H = sumVL * rsqrt(max(h2, 1e-12));
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));

    // 2. 材质参数：感知粗糙度 r → alpha=r²，金属度 → RGB F0。
    const float PI = 3.14159265358979323846;
    float3 baseColor = saturate(material.baseColor);
    float metallic = saturate(material.metallic);
    float r = clamp(material.perceptualRoughness, 0.045, 1.0);
    float alpha = r * r;
    float alpha2 = alpha * alpha;
    float3 F0 = (1.0 - metallic) * float3(0.04, 0.04, 0.04) + metallic * baseColor;

    // 3. D：GGX 分布，完整写出分子和分母。
    float NoH2 = NoH * NoH;
    float d = (1.0 - NoH2) + NoH2 * alpha2;
    float D = alpha2 / (PI * d * d);

    // 4. F：Schlick，手工计算 (1-VoH)^5。
    float oneMinusVoH = 1.0 - VoH;
    float x2 = oneMinusVoH * oneMinusVoH;
    float x5 = x2 * x2 * oneMinusVoH;
    float3 F = F0 + (1.0 - F0) * x5;

    // 5. 相关 Smith：G=2*NoL*NoV/q，G/(4*NoL*NoV)=0.5/q。
    float rootV = sqrt(NoV * NoV * (1.0 - alpha2) + alpha2);
    float rootL = sqrt(NoL * NoL * (1.0 - alpha2) + alpha2);
    float q = max(NoL * rootV + NoV * rootL, 1e-7);
    float visibility = 0.5 / q;
    // 先约简再求值，避免极端掠射时先乘很小的 G 再除很小的分母。
    float3 specularBRDF = D * F * visibility;

    // 6. 漫反射：近似分配剩余能量，金属不保留体漫反射。
    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuseBRDF = kD * baseColor / PI;

    // 7. 渲染方程的单灯项：乘一次 NoL、光色、衰减和阴影。
    float attenuation = max(distanceAttenuation, 0.0) * saturate(shadowAttenuation);
    return (diffuseBRDF + specularBRDF) * max(lightColor, 0.0) * NoL * attenuation;
}
```

这两个版本用于展示“按公式拆成函数”和“在一个函数里展开运算”的对应关系，数学模型相同。接入 Unity 时，位置、纹理、灯光与阴影由引擎提供；材质的 DFG 和光照组合使用这里写出的实现，见 [06 的自包含完整 Shader](06_Unity_URP_Implementation.md)。
