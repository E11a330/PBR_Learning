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

因此 `D` 不是「0～1 的概率」。代码使用等价分母，减轻 `NoH≈1` 时的消减误差：

```hlsl
float alpha2 = alpha * alpha;
float NoH2 = NoH * NoH;
float d = (1.0 - NoH2) + NoH2 * alpha2;
float D = alpha2 / (CPBR_PI * d * d);
```

配套实现将 `r` 限制到 `[0.045,1]`，避免完美镜面极限。**不要**再把 `d*d` 粗暴夹到 `1e-4`，否则低粗糙度高光会被压坏。精确镜面需要 delta 分布处理，不靠将粗糙度设为 0 实现。

## 3. F：Schlick Fresnel

$$F=F_0+(1-F_0)(1-VoH)^5$$

`F0` 是正入射反射率。掠射时，Schlick 的这个版本趋近于 `F90=1`。

金属度工作流的近似：

$$F_0=\operatorname{lerp}(0.04,\;baseColor,\;metallic)$$

非金属的 `0.04` 是常用默认值，不是所有材质的常数。空气到非吸收介质，正入射有：

$$F_0=\left(\frac{\eta-1}{\eta+1}\right)^2$$

例如 `η=1.5 → F0=0.04`。金属涉及复折射率，本代码用 RGB F0 作近似，并不求解完整导体 Fresnel。

实现五次方可以避免通用 `pow`：

```hlsl
float x = 1.0 - VoH;
float x2 = x * x;
float x5 = x2 * x2 * x;
float3 F = F0 + (1.0 - F0) * x5;
```

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

## 写代码时的检查清单

- 先统一 `r / α / α²`，再抄公式。
- N、L、V 同空间归一化，拒绝背面和退化方向。
- F 使用 `VoH`；D 使用 `NoH`；G/V 使用 `NoL` 与 `NoV`。
- `D*F*Vsmith` 与 `D*F*G/(4*NoL*NoV)` 二选一。
- 在单光源组合时乘一次 `NoL`，不要遗漏或重复。
- 公式中间量保留 `float`；结果不要 `saturate`，让后处理处理 HDR。

[对应 HLSL](Shaders/CustomPBR.hlsl) · [接入 URP](06_Unity_URP_Implementation.md)
