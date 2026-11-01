# Unity PBR / BRDF：原理、公式与 Shader 实现

这套笔记用于理解 PBR，并在编写 Shader 时查阅。阅读顺序是：**先建立整体概念，再拆解公式，最后对应到代码**。

每个公式主要回答四个问题：它描述什么、符号是什么、改变参数会怎样影响画面、在 Shader 的哪一步使用。重点保留公式与实际反射效果的联系，完整实现统一放在后面。

## 内容分类

| 笔记 | 主要内容 |
| --- | --- |
| [01 · PBR 基础](01_PBR_Basics.md) | PBR 的含义、反射组成、方向约定、能量与颜色空间 |
| [02 · BRDF 模型分类](02_BRDF_Models.md) | BRDF 是什么；Lambert、Burley 与微表面镜面模型如何分类 |
| [03 · Cook–Torrance DFG](03_Cook_Torrance_DFG.md) | 拆解 GGX D、Schlick F、Smith G，解释分母与 visibility，附数值例子和代码 |
| [04 · 材质参数](04_Material_Parameters.md) | Base Color、Metallic、Roughness、Normal、AO 如何进入公式和贴图 |
| [05 · 渲染方程](05_Rendering_Equation.md) | 从 BRDF 得到像素颜色；直接光、间接光、IBL 与输出处理 |
| [06 · Unity URP 实现](06_Unity_URP_Implementation.md) | 公式与引擎数据的对应，完整 ShaderLab、调试方式与实现边界 |
| [CustomPBR.hlsl](Shaders/CustomPBR.hlsl) | 独立 D/F/G/V 函数、BRDF 组合与单光源计算 |

首次阅读按 01 → 02 → 03 → 04 → 05 → 06；已有基础时，可以直接查 03 的 DFG 和 06 的接入代码。

## 知识结构

```text
PBR：用物理规律约束材质与光照
├── 材质响应：BRDF
│   ├── 漫反射：Lambert / Burley 等
│   └── 镜面反射：Cook–Torrance 类微表面模型
│       ├── D：微表面法线分布
│       ├── F：Fresnel 反射比例与颜色
│       └── G：微表面遮蔽
├── 材质输入：颜色 / 金属度 / 粗糙度 / 法线等
└── 光照组合：直接光 + 间接光 + 自发光
```

## 贯穿笔记的一条主线

$$f_r=f_d+f_s,\qquad f_s=\frac{DFG}{4NoLNoV}$$

BRDF 描述材质本身如何反射。接上具体灯光后，再乘光色、NoL、衰减与场景可见性，得到这盏灯的贡献。不要把“高光公式”与“最终像素颜色”当成同一个东西。

本例为了看清结构，将镜面项写成 `D * F * visibility`，其中 `visibility=G/(4NoLNoV)`；二者含义相同，不能重复使用分母。

## 统一约定

- 全部光照计算使用线性 RGB；返回值保留 HDR。
- N 为法线，V 从表面指向相机，L 从表面指向光源，H 为 V 与 L 的半角方向。
- 感知粗糙度为 r，微表面参数为 `alpha=r²`。公式里的 `alpha²` 因而等于 `r⁴`。
- 示例采用不透明、各向同性、金属度工作流；镜面使用 GGX D + Schlick F + 高度相关 Smith G。
- 漫反射采用带近似 Fresnel 权重的 Lambert；未补偿微表面多次散射，不将其表述为严格的分层能量守恒模型。

## 代码与适用范围

`CustomPBR.hlsl` 是函数库，供 Shader 包含使用；完整 ShaderLab 放在 06 的末尾，含颜色、ORM、法线贴图、主光、逐像素附加光和调试菜单。

接入环境是 Unity 2022.3 / URP 14 / Forward / Linear。代码演示直接光，不包含 IBL、烘焙 GI、ShadowCaster 等附加 Pass、透明、皮肤散射和头发模型。它与 URP/Lit 的实现近似和功能范围不同。

## 目录

```text
Unity-TA-Notes/
└── Rendering/
    └── PBR/
        ├── README.md
        ├── 01_PBR_Basics.md
        ├── 02_BRDF_Models.md
        ├── 03_Cook_Torrance_DFG.md
        ├── 04_Material_Parameters.md
        ├── 05_Rendering_Equation.md
        ├── 06_Unity_URP_Implementation.md
        └── Shaders/
            └── CustomPBR.hlsl
```

## 参考资料与验证范围

笔记为重新编写的中文解释，并非原对话逐字转录。资料核对日期：2026-11-01。

- [PBRT 第 4 版：微表面理论](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory)
- [Filament：材质与光照模型](https://google.github.io/filament/main/filament.html)
- [Unity URP 14：灯光接口](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@14.0/manual/use-built-in-shader-methods-lighting.html)、[纹理采样](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@14.0/manual/writing-shaders-urp-unlit-texture.html)
- Unity 源码：[BRDF.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl)、[Lighting.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl)、[RealtimeLights.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl)
- Unity 源码：[SpaceTransforms.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl)、[Packing.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.core/ShaderLibrary/Packing.hlsl)

文件层级、编码与相对链接已检查；HLSL 函数库、展开函数、调试函数通过独立编译，另有公式数值核对。完整示例的顶点/片元代码也用独立接口替身做了语法检查；这不等于真实 URP 编译。尚未在 Unity Editor 中导入、运行或比较画面。Unity 维护分支会变化，实际接入以本地包版本为准。
