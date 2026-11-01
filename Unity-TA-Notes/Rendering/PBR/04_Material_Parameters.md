# 04 · 材质参数与贴图

[返回目录](README.md) · [上一篇](03_Cook_Torrance_DFG.md) · [下一篇：渲染方程](05_Rendering_Equation.md)

## 参数 → 公式 → 观感

| 参数 | 在公式中的位置 | 调整后的主要变化 |
| --- | --- | --- |
| Base Color | 非金属漫反射颜色；金属 F0 | 反射光的颜色组成 |
| Metallic `m` | `F0=lerp(0.04,baseColor,m)`、`fd∝(1-m)` | 在非金属与金属参数解释之间混合 |
| Roughness `r` | `α=r²`，进入 D 与 G | 高光宽度、峰值与微遮蔽 |
| Smoothness `s` | `r=1-s` | 与粗糙度反向 |
| Normal | 改变 N 和相关点乘 | 光照方向与细节 |
| AO | 间接光的遮蔽近似 | 缝隙与接触处的环境光强度 |
| Emission | 渲染方程中的独立发光项 | 表面自身发光，不由 BRDF 计算 |

## Base Color：颜色的含义随工作流变化

非金属表面的 Base Color 主要表达体散射的颜色；非金属高光通常接近无色。纯金属的 Base Color 则表达有颜色的镜面 F0，不能一边把它当金属反射色，一边保留同色的强漫反射。

尽量使用不含烘焙高光和定向阴影的 Base Color 贴图，否则实时灯光会再叠加一次明暗。

## 金属度不是「反光强度」

干净、均一的材质区域通常接近 0 或 1。中间值可来自纹理过滤、覆盖混合或美术近似；它不表示「导电率 50%」。油漆覆盖的金属，在可见涂层处主要呈现非金属响应；生锈区域也不宜因底材是铁就全设为 1。

`F0=0.04` 是本例固定的非金属基线。若要表达宝石、液体等不同折射率，可将非金属 F0 参数化，但需要保持工作流含义一致。

## 粗糙度与光滑度

本笔记对输入先做：

$$r=\operatorname{clamp}(r_{input},0.045,1),\quad \alpha=r^2,\quad \alpha^2=r^4$$

下限 `0.045` 是本教育实现的数值选择，不是所有 Unity Shader 的统一规则。URP 也有自己的精度下限与优化项，应按本地版本检查。

Normal Map 解决可分辨的表面方向变化；粗糙度描述更细小的方向统计。远处法线细节被过滤后，高光仍可能闪烁，通常还需要高光抗锯齿或法线方差修正。

## 导入与通道约定

| 贴图 | 导入/采样要点 |
| --- | --- |
| Base Color | 颜色贴图通常勾选 sRGB；光照计算用解码后的线性值 |
| Metallic / Roughness / AO | 数据贴图关闭 sRGB；按实际通道读取 |
| Normal | 使用 Unity Normal map 类型与解包函数，不直接将 RGB 当世界法线 |
| HDR 环境图 | 走引擎对应 HDR 解码与反射探针采样流程 |

URP/Lit 常见 Metallic 工作流是金属度读 R，光滑度可来自金属贴图 A；材质选项也可能让光滑度来自 Base Map A。**先确认材质选项，再读取通道**，不要将 roughness 图直接当 smoothness 图。

ORM（R=AO、G=Roughness、B=Metallic）是另一种常见打包约定，不等于 Unity/Lit 的默认通道布局。自写 Shader 可以选用它，但要自己正确解包和转换。

## 法线接线

切线空间法线需要通过 TBN 转到世界空间，再与世界空间 L、V 点乘。处理好模型切线的符号、负缩放和插值后的归一化。06 的完整示例已包含这条接线；使用默认平坦法线时，结果接近原来的网格法线。

## AO 的位置

AO 主要近似未解析几何对间接光的遮挡，不应不加区分地把所有直接高光乘暗。镜面环境遮蔽也通常需要不同处理。配套直接光函数不接收 AO；未来加入间接光后再按光照分量应用。

Unity 参数初始化可对照 [URP BRDF.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl)。本例的角度相关漫反射权重与该源码不完全相同。

## 材质参数如何共同进入 BRDF

将颜色记为 C，金属度记为 m：

$$F_0=(1-m)\,0.04+mC$$

$$k_D=(1-F)(1-m),\qquad f_d=k_D\frac{C}{\pi}$$

第一条式子决定镜面反射的基础颜色，第二条式子决定漫反射保留多少。因此 Metallic 不是独立的亮度滑条，而是同时改变镜面参数与漫反射分配。

当 m=0 时，F0 为无色的 0.04，C 主要提供漫反射颜色；当 m=1 时，F0=C，而漫反射为零。中间值是工作流中的混合近似，不应解释成材质有某个百分比的导电率。

Normal Map 影响的是 N，由此改变 NoL、NoV、NoH；Roughness 通过 alpha 改变 D 和 G。两者都能让高光变得复杂，但不是同一条控制路径。

## 附：从贴图生成参数的代码

以下片段位于片元函数中。假设纹理、采样器和 uv 已声明；完整声明见 [06](06_Unity_URP_Implementation.md)。本例采用 ORM：R=AO、G=感知粗糙度、B=金属度。

```hlsl
float3 sampledBase = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv).rgb;
float3 orm = SAMPLE_TEXTURE2D(_ORMMap, sampler_ORMMap, uv).rgb;

CPBR_Material material;
material.baseColor = sampledBase * _BaseColor.rgb;
material.metallic = saturate(orm.b * _Metallic);
material.perceptualRoughness = clamp(orm.g * _Roughness, 0.045, 1.0);
// orm.r 留给间接光遮蔽；当前示例只实现直接光。
```

这里的面板参数是乘法系数：例如 G 通道为 0.4，粗糙度系数为 0.5，最终 r=0.2。要使用贴图原值，系数设为 1；用默认白图时，滑条直接决定参数。

若输入是 Smoothness，应先用 `r=1-smoothness` 转换，再交给函数库。不要同时在贴图读取处与 `CPBR_RoughnessToAlpha` 中将 r 平方。

颜色纹理采样为线性值后再参与光照；ORM 不作 sRGB 解码。存储值 0.5 若被按 sRGB 解码，大约会变成 0.214，用在粗糙度上会明显改变 D/G 的输入。
