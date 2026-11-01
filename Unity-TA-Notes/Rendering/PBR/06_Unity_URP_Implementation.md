# 06 · 将 PBR 公式接入 Unity URP

[返回目录](README.md) · [DFG 公式](03_Cook_Torrance_DFG.md) · [函数库](Shaders/CustomPBR.hlsl)

## 1. 先确定每一层的职责

前面几篇讨论材质与反射模型；这里将它们接到真实的网格、纹理和灯光数据上。代码主要分为三层：

| 层次 | 负责什么 | 对应位置 |
| --- | --- | --- |
| 几何与材质输入 | 世界位置、N/V、贴图、金属度与粗糙度 | ShaderLab 的 Vert / Frag |
| BRDF | D、F、G/V、漫反射和镜面组合 | `CustomPBR.hlsl` |
| 光照组合 | 主光与附加光、衰减、阴影与求和 | `EvaluateOneLight` 与灯循环 |

这样修改材质公式时，不必同时改写灯光接口；改变纹理格式时，也不必改动 DFG 的数学表达式。

## 2. 几何方向从哪里来

N 来自网格法线或法线贴图，V 使用 `GetWorldSpaceNormalizeViewDir(positionWS)`，L 使用 URP `Light.direction`。本例统一在世界空间计算，并在片元阶段重新归一化方向。

顶点阶段归一化，并不保证插值后仍是单位向量。法线变换也需要正确处理非均匀缩放，所以使用引擎的法线/切线变换接口，而不是简单套用位置变换。

对于法线贴图，切线空间方向 `(nx,ny,nz)` 通过 T、B、Ng 转到世界空间：

$$N=\operatorname{normalize}(n_xT+n_yB+n_zN_g)$$

Ng 是网格法线，T 是切线，B 是副切线。平坦法线 `(0,0,1)` 会得到 Ng；x/y 分量则让法线朝表面切线方向偏转。

实现中将插值后的 T 对 Ng 重新正交化，再用 `cross(Ng,T)*sign` 得到 B。sign 包含切线手性与奇数次负缩放符号，避免镜像方向翻转。模型需要有有效 UV、法线与切线。

## 3. 材质数据怎样进入公式

| 输入 | 预处理 | 进入哪里 |
| --- | --- | --- |
| Base Map × Base Color | 线性 RGB | 非金属漫反射颜色 / 金属 F0 |
| ORM.B × Metallic | 夹到 0～1 | F0 混合与漫反射分配 |
| ORM.G × Roughness | 本例 r 至少 0.045，之后 alpha=r² | D 与 G/V |
| Normal Map | 解包并通过 TBN 转世界空间 | N 及相关点乘 |

ORM.R 是 AO；当前只计算直接光，因此不将它乘到最终颜色。三张纹理共用 Base Map 的 Tiling/Offset；Base Map 按 sRGB 颜色导入，ORM 关闭 sRGB，法线使用 Normal map 导入类型。

贴图取值还会乘面板系数。系数为 1 才代表按 ORM 原值使用；默认白图时，面板值直接决定 Metallic 与 Roughness。

## 4. 光源数据怎样进入公式

| URP Light 字段 | 在单灯计算中的用途 |
| --- | --- |
| `direction` | L，决定 NoL、H、D/F/G |
| `color` | 光色与强度 |
| `distanceAttenuation` | 距离与聚光等衰减，不重复手算逆平方 |
| `shadowAttenuation` | 场景阴影，与微表面 G 分开计算 |

主光通过世界位置生成阴影坐标后读取；附加光逐盏读取，再用同一套 BRDF 求值。调用 `CPBR_EvaluateDirect` 得到的是最终单灯贡献，已包括 NoL 和衰减，不能再次相乘。

这里面向 **Unity 2022.3 / URP 14 / Forward / Linear**，附加光使用 Per Pixel。Forward+ 有不同的灯光遍历要求，不能只照搬普通附加光循环。

## 5. 调试与实现边界

先将直接光、材质和输出问题分开检查：NoL 验证方向，BaseColor 验证纹理，Diffuse / Specular 隔离反射分量，D/F/G 验证镜面模型内部。

完整示例提供两个调试菜单：Debug Mode 查看普通分量，DFG Debug 查看 D/F/G，后者开启时优先显示。正常光照使用 `DFG Debug=Off`、`Debug Mode=Shaded`。

| 显示项 | 观察内容 |
| --- | --- |
| BaseColor | 不受灯光影响的材质颜色 |
| Normal / NoL | 世界法线与主光方向关系 |
| Diffuse / Specular | 尚未乘灯色、外层 NoL 与场景阴影的 BRDF |
| D / F / G | 高光方向分布、Fresnel 与微遮蔽 |

D 和 Specular 为显示做了压缩，正式光照使用原始值。精确数值应读线性浮点数据，截图还受显示编码等因素影响。除法线、底色和 NoL 外，高光内部调试在无效背面/背光方向返回黑色。

| 现象 | 优先检查 |
| --- | --- |
| 高光方向异常 | N/V/L 的空间、方向与归一化 |
| 粗糙度效果反向 | Smoothness/Roughness、纹理通道及平方约定 |
| 掠射异常变暗或爆亮 | G 与 visibility 是否混用，分母与退化方向保护 |
| 金属多数区域很暗 | 是否缺少环境镜面反射 |
| 亮度或点光衰减异常 | NoL、距离衰减或阴影是否重复相乘 |
| 法线接入后方向错乱 | 法线解包、模型切线、手性和负缩放 |
| 与 URP/Lit 差异很大 | 光照功能、近似公式、材质输入和曝光是否一致 |

示例支持颜色/ORM/法线、主光、逐像素附加光、距离/聚光衰减、实时阴影接收与雾。没有 IBL、烘焙 GI、ShadowCaster / DepthOnly / DepthNormals / Meta Pass、屏幕空间主光阴影、Cookies、Rendering Layers、SSAO、Shadowmask、Forward+、透明或 XR/实例化。

因此它能接收实时阴影，但不投射阴影；放入反射探针也不会自动产生环境反射，需要另加对应采样与组合。这些范围区别比单纯调亮暗更应先确认。

## 6. 附：完整 ShaderLab 代码

将 `Shaders/CustomPBR.hlsl` 与 `CustomPBRExample.shader` 放在 Unity 同一目录，例如 `Assets/Shaders`；下面代码保存为后者。材质选择 `Unity-TA-Notes/CustomPBRExample`。默认纹理为白图和平坦法线，不赋图也能使用面板常量。

函数库核心是 `CPBR_EvaluateBRDF` 与 `CPBR_EvaluateDirect`。前者返回材质响应，后者将响应转换成单灯贡献；想对照数学表达式时看 03，想修改贴图约定时看 04。

```shaderlab
Shader "Unity-TA-Notes/CustomPBRExample"
{
    Properties
    {
        _BaseColor("Base Color", Color) = (0.5, 0.3, 0.2, 1)
        _BaseMap("Base Map", 2D) = "white" {}
        _Metallic("Metallic Multiplier", Range(0, 1)) = 0
        _Roughness("Roughness Multiplier", Range(0.045, 1)) = 0.5
        [NoScaleOffset] _ORMMap("ORM: R=AO G=Roughness B=Metallic", 2D) = "white" {}
        [Normal][NoScaleOffset] _BumpMap("Normal Map", 2D) = "bump" {}
        _NormalScale("Normal Scale", Range(0, 2)) = 1
        [Enum(Shaded,0,Normal,1,NoL,2,Diffuse,3,Specular,4,BaseColor,5)]
        _DebugMode("Debug Mode", Float) = 0
        [Enum(Off,0,D,1,F,2,G,3)]
        _DebugDFG("DFG Debug (overrides Debug Mode)", Float) = 0
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" }
        Pass
        {
            Name "Forward"
            Tags { "LightMode"="UniversalForward" }
            Cull Back
            ZWrite On
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Packing.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "CustomPBR.hlsl"

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_ORMMap); SAMPLER(sampler_ORMMap);
            TEXTURE2D(_BumpMap); SAMPLER(sampler_BumpMap);
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _BaseMap_ST;
                float _Metallic;
                float _Roughness;
                float _NormalScale;
                float _DebugMode;
                float _DebugDFG;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float4 tangentWS : TEXCOORD2;
                float2 uv : TEXCOORD3;
                float fogFactor : TEXCOORD4;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs p = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs n = GetVertexNormalInputs(input.normalOS, input.tangentOS);
                output.positionCS = p.positionCS;
                output.positionWS = p.positionWS;
                output.normalWS = n.normalWS;
                float sign = input.tangentOS.w * GetOddNegativeScale();
                output.tangentWS = float4(n.tangentWS, sign);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.fogFactor = ComputeFogFactor(p.positionCS.z);
                return output;
            }

            // 仅用于观察中间结果，不参与正常模式的光照计算。
float4 DebugPBR(CPBR_Material material, float3 N, float3 V, Light light, int mode)
{
    N = CPBR_SafeNormalize(N);
    V = CPBR_SafeNormalize(V);
    float3 L = CPBR_SafeNormalize(light.direction);
    float NoL = saturate(dot(N, L));
    float NoV = saturate(dot(N, V));
    if (mode == 0) return float4(N * 0.5 + 0.5, 1); // 方向映射到 RGB。
    if (mode == 1) return float4(float3(NoL, NoL, NoL), 1);
    if (NoL <= 0 || NoV <= 0) return float4(0, 0, 0, 1);
    if (dot(V + L, V + L) < 1e-12) return float4(0, 0, 0, 1);

    float3 H = CPBR_SafeNormalize(V + L);
    float alpha = CPBR_RoughnessToAlpha(material.perceptualRoughness);
    float D = CPBR_DistributionGGX(saturate(dot(N, H)), alpha);
    float3 F = CPBR_FresnelSchlick(saturate(dot(V, H)),
        CPBR_F0(material.baseColor, material.metallic));
    float G = CPBR_GeometrySmithGGXCorrelated(NoL, NoV, alpha);
    float3 diffuseBRDF, specularBRDF;
    CPBR_EvaluateBRDF(material, N, V, L, diffuseBRDF, specularBRDF);
    if (mode == 2) return float4(float3(D, D, D) / (1.0 + D), 1);
    if (mode == 3) return float4(F, 1);
    if (mode == 4) return float4(float3(G, G, G), 1);
    if (mode == 5) return float4(diffuseBRDF, 1);
    return float4(specularBRDF / (1.0 + specularBRDF), 1);
}

            float3 EvaluateOneLight(CPBR_Material material, float3 N, float3 V, Light light)
            {
                return CPBR_EvaluateDirect(material, N, V, light.direction,
                    light.color, light.distanceAttenuation, light.shadowAttenuation);
            }

            float4 Frag(Varyings input) : SV_Target
            {
                // 1. 采材质。三张贴图共用 Base Map 的 Tiling / Offset。
                float2 uv = input.uv;
                float3 baseSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv).rgb;
                float3 orm = SAMPLE_TEXTURE2D(_ORMMap, sampler_ORMMap, uv).rgb;
                CPBR_Material material;
                material.baseColor = baseSample * _BaseColor.rgb;
                material.metallic = saturate(orm.b * _Metallic);
                material.perceptualRoughness = clamp(orm.g * _Roughness, 0.045, 1.0);
                // orm.r 留给将来的间接光遮蔽；本示例不把它乘到直接光上。

                // 2. 将法线贴图提供的偏转，换成世界空间方向。
                float4 packedNormal = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv);
                float3 normalTS = UnpackNormalScale(packedNormal, _NormalScale);
                float3 Ng = normalize(input.normalWS);
                float3 T = normalize(input.tangentWS.xyz - Ng * dot(Ng, input.tangentWS.xyz));
                float3 B = cross(Ng, T) * input.tangentWS.w;
                float3 N = normalize(normalTS.x * T + normalTS.y * B + normalTS.z * Ng);
                float3 V = GetWorldSpaceNormalizeViewDir(input.positionWS);

                // 3. 获取主光和主光阴影。
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(input.positionWS));

                // 调试模式直接返回，不叠加雾或其他灯光。
                int mode = (int)_DebugMode;
                int dfgMode = (int)_DebugDFG;
                if (dfgMode >= 1 && dfgMode <= 3)
                    return DebugPBR(material, N, V, mainLight, dfgMode + 1);
                if (mode == 5) return float4(material.baseColor, 1);
                if (mode == 1 || mode == 2)
                    return DebugPBR(material, N, V, mainLight, mode - 1);
                if (mode == 3 || mode == 4)
                    return DebugPBR(material, N, V, mainLight, mode + 2);

                // 4. 每盏灯单独计算，再把颜色相加。
                float3 color = EvaluateOneLight(material, N, V, mainLight);
                #if defined(_ADDITIONAL_LIGHTS)
                    uint count = GetAdditionalLightsCount();
                    for (uint i = 0u; i < count; ++i)
                    {
                        Light light = GetAdditionalLight(i, input.positionWS, half4(1,1,1,1));
                        color += EvaluateOneLight(material, N, V, light);
                    }
                #endif
                color = MixFog(color, input.fogFactor);
                return float4(color, 1);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
```

代码已做独立 HLSL 编译与公式数值核对；整段顶点/片元代码使用接口替身做语法检查。尚未在 Unity Editor 中使用真实 URP 头文件导入、运行或做画面验证，需要在目标项目中完成这部分验证。
