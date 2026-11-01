# Unity 角色渲染：PBR / BRDF 学习笔记

面向「看懂公式 → 调材质 → 自己写 Shader」的中文速查笔记。核心是 Cook–Torrance 镜面 BRDF 的 **D、F、G**，配套独立 HLSL 函数库和 URP 接入示例。

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

| 文件 | 解决的问题 |
| --- | --- |
| [01 · PBR 基础](01_PBR_Basics.md) | PBR、BRDF、向量、能量与颜色空间是什么？ |
| [02 · BRDF 模型分类](02_BRDF_Models.md) | Lambert、Burley、Phong、GGX 各负责什么？ |
| [03 · Cook–Torrance DFG](03_Cook_Torrance_DFG.md) | D、F、G 怎么算？为什么代码中会出现 V？ |
| [04 · 材质参数](04_Material_Parameters.md) | Base Color、Metallic、Roughness、Normal、AO 怎么用？ |
| [05 · 渲染方程](05_Rendering_Equation.md) | BRDF 怎样变成像素颜色？直接光与 IBL 怎样分工？ |
| [06 · Unity URP 实现](06_Unity_URP_Implementation.md) | 如何接入主光、附加光和阴影？如何排查错误？ |
| [CustomPBR.hlsl](Shaders/CustomPBR.hlsl) | GGX D + Schlick F + 高度相关 Smith G/V + 单光源计算 |

推荐顺序：01 → 02 → **03** → 04 → 05 → 06。写 Shader 时优先查 03 的公式与 06 的接线方式。

## 本笔记统一约定

- 不透明、各向同性、金属度工作流；所有光照计算在线性 RGB 中完成。
- `N` 为法线，`V` 从表面指向相机，`L` 从表面指向光源，`H = normalize(V + L)`。
- 感知粗糙度为 `r`，微表面粗糙度为 `α = r²`；公式中的 `α²` 因而是 `r⁴`。
- 镜面项使用单次散射 GGX；漫反射使用带近似 Fresnel 权重的 Lambert。
- 返回值保留 HDR 范围，不在 BRDF 函数内做色调映射或 Gamma 编码。

## 代码怎么用

`CustomPBR.hlsl` 是可包含的函数库，**不是可以直接拖到材质上的完整 ShaderLab Shader**。将它放进 Unity 项目，再按 [06 的完整 ShaderLab 示例](06_Unity_URP_Implementation.md#最小-shaderlab-示例) 创建 `.shader` 文件。

接入示例面向 **Unity 2022.3 / URP 14 的 Forward 路径**，演示逐像素直接光和实时阴影接收。函数库本身不依赖 URP 头文件。未实现 IBL、烘焙 GI、投影阴影 Pass、透明、SSS、清漆和各向异性，也不与 URP/Lit 逐像素等价。角色皮肤、头发与布料通常还需要专用模型。

## 资料与核对范围

以下是继续学习和对照源码的入口；正文为按本目录重新编写的教学笔记，并非原对话逐字转录。核对日期：2026-11-01。

1. [PBRT 第 4 版：微表面理论](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory)——NDF、Smith 遮蔽及单次散射假设。
2. [Filament：材质模型](https://google.github.io/filament/main/filament.html#materialsystem)——实时渲染的参数化与近似选择。
3. [Unity URP 14：自定义 Shader 的光照方法](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@14.0/manual/use-built-in-shader-methods-lighting.html)——URP 光照接口。
4. [Unity BRDF.hlsl（2022.3/staging）](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl)——材质初始化及优化后的直接镜面计算。
5. [Unity Lighting.hlsl（2022.3/staging）](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl)——BRDF、光色、衰减和余弦项的组合位置。
6. [Unity RealtimeLights.hlsl（2022.3/staging）](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl)——主光、附加光及 Forward+ 遍历差异。

Unity 链接使用可变维护分支，项目集成时以本地 Package Cache 的实际版本为准。这里保留清晰的 D/F/G 分解来帮助学习，不照抄引擎中的优化表达式。

## 验证与使用边界

交付时已检查文件层级、相对链接和 UTF-8 编码；HLSL 核心通过 Windows D3DCompile 的 Shader Model 5.0 编译检查，并对照独立公式做数值边界检查。未在 Unity Editor 中导入或做画面回归；06 中的 URP 示例需要在目标项目中验证变体与渲染设置。

解压后可将 `Unity-TA-Notes` 作为仓库根目录；若现有仓库已叫这个名字，只需合并其中的 `Rendering` 文件夹。
