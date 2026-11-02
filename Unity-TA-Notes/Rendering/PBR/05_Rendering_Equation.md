# 05 · 渲染方程、直接光与 IBL

[返回目录](README.md) · [上一篇](04_Material_Parameters.md) · [下一篇：URP 实现](06_Unity_URP_Implementation.md)

## BRDF 只负责材质响应

反射表面的渲染方程可以写成：

$$
L_o(x,V)=L_e(x,V)+\int_{\Omega^+}f_r(x,L,V)L_i(x,L)(N\cdot L)\,d\omega_L
$$

| 项 | 含义 |
| --- | --- |
| `Lo` | 向相机方向离开表面的辐亮度 |
| `Le` | 表面发射的辐亮度 |
| `fr` | 漫反射 + 镜面反射 BRDF |
| `Li` | 从某方向到达表面的辐亮度 |
| `N·L` | 投影面积导致的余弦因子 |
| `dω` | 方向积分的立体角微元 |

可见性可以包含在 `Li` 中，也可以显式写成额外因子。实现时选择一种组织方式，避免把阴影重复相乘。点光源与理想方向光属于方向上的 delta 光源，需要专门求值；实时灯光接口返回的光色/衰减已经采用引擎自己的约定。

## 直接光：对已知光源求和

实时渲染常用：

$$C_{direct}=\sum_j[f_d(L_j,V)+f_s(L_j,V)]\,C_j\,NoL_j\,A_j\,S_j$$

`Cj` 包含光色与强度，`Aj` 包含距离/聚光衰减，`Sj` 为阴影因子。点光源在理想情况下随距离平方反比衰减，游戏引擎还会增加光源范围的平滑截断。

在 URP 中，若已经使用 `Light.distanceAttenuation`，不要自己再乘一次 `1/distance²`。`Light.shadowAttenuation` 也只在最终计算中使用一次。参见 [Unity Lighting.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl) 中组合光照项的位置。

## 环境与间接光：不能只看当前灯

间接光指经过其他表面反弹后到达当前表面的光。环境图则是入射方向光照的表示：天空直接照到表面时，物理上属于直接照明；环境图也可以包含周围物体反射的结果。因此 IBL 不等同于“已经反弹过的间接光”。

实时引擎经常将环境照明与 GI 放在相近的计算模块处理。这里将它们一起讨论，是实现上的组织方式；具体仍可能混用光照贴图、光照探针、反射探针和屏幕空间方法，而非实时解完整积分。

IBL（Image-Based Lighting）用环境图代表从不同方向来的光。纯金属没有体漫反射；若只实现直接光而无环境镜面反射，很多朝向会很暗。

### 漫反射 IBL

对纯 Lambert：

$$E(N)=\int_{\Omega^+}L_i(L)(N\cdot L)\,d\omega_L,\quad L_{diffuse}=\frac{c_d}{\pi}E(N)$$

但某些引擎返回的卷积结果已含 `1/π`。必须确认接口返回的是 irradiance `E`，还是已经归一化的 diffuse lighting；不要看到 Lambert 就再除一次 π。

### 镜面 IBL 与 split-sum

常见近似把环境预过滤与 BRDF 积分拆开：

$$L_{specular}\approx prefilteredEnv(R,r)\,[F_0 A(NoV,r)+F_{90}B(NoV,r)]$$

其中 `R=reflect(-V,N)`，`A/B` 是从 Schlick Fresnel 的两个系数得到的 BRDF 积分项。本笔记使用 `F90=1` 时才可简写为 `F0*A+B`。这是 split-sum 的结构示意；实际引擎可能采用解析拟合、不同参数化或能量补偿，不能脱离对应实现只替换这一行。

环境预过滤、粗糙度到 mip 的映射、采样分布和 BRDF LUT 必须配套。不能把任意模糊 cubemap 直接乘当前直接光的 `D*F*G`，也不能再给 IBL 乘某个单独方向的 `NoL`。

`DFG LUT` 是行业里对环境 BRDF 预积分表的常见叫法；它与 [03 中直接光的三个因子 D、F、G](03_Cook_Torrance_DFG.md) 有联系，但不是三个独立贴图通道。进一步阅读：[Filament 的 IBL 章节](https://google.github.io/filament/main/filament.html#lighting/imagebasedlights)。

## 补充：从积分到采样

若按方向概率密度 `p(ω)` 采样半球，用 `ω_j` 表示第 j 个入射样本方向，蒙特卡洛估计为：

$$L_o-L_e\approx\frac{1}{M}\sum_{j=1}^{M}\frac{f_r(\omega_j,V)\,L_i(\omega_j)\,\max(N\cdot\omega_j,0)}{p(\omega_j)}$$

M 为样本数，`L_i(ω_j)` 是该方向的入射辐亮度；下标 i 表示 incoming，与样本编号 j 分开。PDF 按立体角定义，并应在被积函数非零的区域有非零采样概率。推导与条件可对照 [PBRT 蒙特卡洛积分](https://www.pbr-book.org/4ed/Monte_Carlo_Integration/Monte_Carlo_Basics)。

分母 PDF 不能漏。普通 NDF 采样用 `p_H(H)=D(H)·NoH` 时，镜面反射方向的 PDF 为 `p_L(L)=p_H(H)/(4|V·H|)`；若改用可见法线采样，就要从它自己的 `p_H` 转换，不能继续套普通 NDF 的 PDF。这里只解释积分权重，不提供完整的 IBL 预计算实现。

## 直接光、间接光与输出

```text
最终线性 HDR = 显式实时灯的漫反射 + 显式实时灯的镜面
             + 其余环境/GI 的漫反射与镜面 + 自发光
显示结果     = 曝光 / 色调映射 / 显示编码等输出处理
```

这里按实现模块分组，环境/GI 分量可能包含物理上的直接或间接照明。配套 HLSL 只实现显式实时灯的两个直接光分量。它不自动补环境亮度，也不输出已经 Gamma 编码的颜色。

## 将公式安排到执行流程

| 频率 | 计算内容 |
| --- | --- |
| 每顶点 | 位置、法线和切线空间变换，准备插值数据 |
| 每片元、灯循环之前 | 采材质贴图，构建 N，计算 V，以及可预计算的 alpha/F0 |
| 每盏灯 | 读取 L 与光色/衰减，计算 H、D/F/G，得到该灯贡献 |
| 灯循环之后 | 加间接光与自发光，应用雾和后续输出处理 |

教育函数库为了保持单光源接口独立，会在函数内重复做归一化和材质转换。优化时可以将这些共享数据提出灯循环，但应保持计算语义一致。

多灯求和不能先把光方向相加再计算 BRDF，因为高光对方向的响应是非线性的；应对每个方向分别求值，再相加颜色。

## 附：直接光求和代码

下面假设材质、N、V 与两个 Light 已准备好，完整接口见 06：

```hlsl
float3 direct = float3(0, 0, 0);
direct += CPBR_EvaluateDirect(material, N, V, light0.direction,
    light0.color, light0.distanceAttenuation, light0.shadowAttenuation);
direct += CPBR_EvaluateDirect(material, N, V, light1.direction,
    light1.color, light1.distanceAttenuation, light1.shadowAttenuation);
```

每次调用已经乘过 NoL、距离衰减和阴影，不要在求和后再乘一次。也不要除以灯光数量；额外光源本来就应该增加照明。

例如 03 的正视条件下，一盏单位白光每通道约贡献 0.356507，两盏相同方向的单位白光就约为 0.713014。

自发光只在求和后加入一次。线性 HDR 可以大于 1，不应在光照函数末尾直接 `saturate(color)`，否则会截掉曝光和色调映射需要的信息。
