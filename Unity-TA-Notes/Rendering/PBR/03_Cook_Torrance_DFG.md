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

调试用的 G 函数由同一套受保护的 V 乘回 `4 NoL NoV` 得到。因此当分母下限生效时，它也继承了这项近似，并不是未加保护的解析 G；常规角度下两者一致。

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

## 12. 对应 HLSL 实现

函数库将基础公式分别封装为 D、F、visibility 函数，再组合为 BRDF 和单灯贡献。下面将调用过程展开，便于对照前面的公式；它依赖 [CustomPBR.hlsl](Shaders/CustomPBR.hlsl) 的基础函数。

```hlsl
float3 ExplainDirectPBR(
    CPBR_Material material,
    float3 normalWS, float3 viewDirWS, float3 lightDirWS,
    float3 lightColor, float distanceAttenuation, float shadowAttenuation)
{
    // 第 1 步：拒绝无方向的输入，再统一为单位向量。
    if (dot(normalWS, normalWS) < 1e-12 || dot(viewDirWS, viewDirWS) < 1e-12
        || dot(lightDirWS, lightDirWS) < 1e-12)
        return float3(0, 0, 0);
    float3 N = CPBR_SafeNormalize(normalWS);
    float3 V = CPBR_SafeNormalize(viewDirWS);
    float3 L = CPBR_SafeNormalize(lightDirWS);

    // 第 2 步：将方向变成公式使用的余弦值。
    float NoL = saturate(dot(N, L));
    float NoV = saturate(dot(N, V));
    if (NoL <= 0.0 || NoV <= 0.0)
        return float3(0, 0, 0);
    float3 sumVL = V + L;
    if (dot(sumVL, sumVL) < 1e-12)
        return float3(0, 0, 0);
    float3 H = CPBR_SafeNormalize(sumVL);
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));

    // 第 3 步：将美术参数转成 BRDF 参数。
    float3 baseColor = saturate(material.baseColor);
    float metallic = saturate(material.metallic);
    float alpha = CPBR_RoughnessToAlpha(material.perceptualRoughness);
    float3 F0 = CPBR_F0(baseColor, metallic);

    // 第 4 步：代入 D、F、G 的实现。本例用已合并分母的 visibility。
    float D = CPBR_DistributionGGX(NoH, alpha);
    float3 F = CPBR_FresnelSchlick(VoH, F0);
    float visibility = CPBR_VisibilitySmithGGXCorrelated(NoL, NoV, alpha);
    float3 specularBRDF = D * F * visibility;

    // 第 5 步：给漫反射分配剩余能量，并排除纯金属漫反射。
    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuseBRDF = kD * baseColor / CPBR_PI;

    // 第 6 步：从材质响应变成这盏灯的颜色贡献。
    float attenuation = max(distanceAttenuation, 0.0) * saturate(shadowAttenuation);
    return (diffuseBRDF + specularBRDF) * max(lightColor, 0.0) * NoL * attenuation;
}
```

一般接入直接调用 `CPBR_EvaluateDirect`。如果要修改 D/F/G 的数学表达式，修改对应基础函数；如果要接灯光、贴图或改变坐标空间，查看 [06 的完整 Shader](06_Unity_URP_Implementation.md)。
