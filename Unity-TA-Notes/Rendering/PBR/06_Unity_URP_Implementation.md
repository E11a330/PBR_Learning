# 06 · Unity URP 接入与调试

[返回目录](README.md) · [上一篇](05_Rendering_Equation.md) · [HLSL 源码](Shaders/CustomPBR.hlsl)

## 目标与前提

以下示例面向 **Unity 2022.3、URP 14、Universal Renderer 的 Forward 路径**。先将项目 Color Space 设置为 Linear，附加光设置为 Per Pixel，并准备有法线的网格、一个方向光和相机。

示例包含主光与逐像素附加光、距离/聚光衰减、实时阴影接收和雾。不实现环境反射、烘焙 GI、光照探针、Light Cookies、Rendering Layers、SSAO、Lightmap Shadowmask、XR/实例化或 Forward+ 灯光遍历。它用于检查直接光公式，不能替代生产用 URP/Lit。

## 函数接口

| 函数 | 返回值/用途 |
| --- | --- |
| `CPBR_RoughnessToAlpha(r)` | 从感知粗糙度得到 α |
| `CPBR_DistributionGGX(NoH,alpha)` | D，标量 |
| `CPBR_FresnelSchlick(VoH,F0)` | F，RGB |
| `CPBR_VisibilitySmithGGXCorrelated(NoL,NoV,alpha)` | V = G / (4 NoL NoV) |
| `CPBR_GeometrySmithGGXCorrelated(...)` | G，用于单独观察 |
| `CPBR_EvaluateBRDF(...)` | 输出漫反射、镜面 BRDF，不含灯光或 NoL |
| `CPBR_EvaluateDirect(...)` | 返回单光源线性 HDR 贡献，已乘 NoL 与两种衰减 |

方向统一使用世界空间：`normalWS`、`cameraPositionWS-positionWS`、`Light.direction`。函数内部会归一化，但它无法修复空间混用或 NaN 输入。

## 最小 ShaderLab 示例

1. 将仓库里的 `Shaders/CustomPBR.hlsl` 复制到 Unity 的 `Assets/Shaders/CustomPBR.hlsl`。
2. 在同一个文件夹创建 `CustomPBRExample.shader`，粘贴下面的完整代码。
3. 创建材质，选择 `Unity-TA-Notes/CustomPBRExample`，赋给网格。
4. 用普通方向光旋转观察；测试阴影时让其他带 ShadowCaster 的物体遮住它。

```shaderlab
Shader "Unity-TA-Notes/CustomPBRExample"
{
    Properties
    {
        _BaseColor("Base Color", Color) = (0.5, 0.3, 0.2, 1)
        _Metallic("Metallic", Range(0, 1)) = 0
        _Roughness("Perceptual Roughness", Range(0.045, 1)) = 0.5
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
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "CustomPBR.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float _Metallic;
                float _Roughness;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float fogFactor : TEXCOORD2;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs p = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionCS = p.positionCS;
                output.positionWS = p.positionWS;
                output.normalWS = TransformObjectToWorldNormal(input.normalOS);
                output.fogFactor = ComputeFogFactor(p.positionCS.z);
                return output;
            }

            float3 EvaluateOneLight(CPBR_Material material, float3 N, float3 V, Light light)
            {
                return CPBR_EvaluateDirect(material, N, V, light.direction,
                    light.color, light.distanceAttenuation, light.shadowAttenuation);
            }

            float4 Frag(Varyings input) : SV_Target
            {
                float3 N = normalize(input.normalWS);
                float3 V = GetWorldSpaceNormalizeViewDir(input.positionWS);
                CPBR_Material material;
                material.baseColor = _BaseColor.rgb;
                material.metallic = _Metallic;
                material.perceptualRoughness = _Roughness;

                float4 shadowCoord = TransformWorldToShadowCoord(input.positionWS);
                Light mainLight = GetMainLight(shadowCoord);
                float3 color = EvaluateOneLight(material, N, V, mainLight);

                #if defined(_ADDITIONAL_LIGHTS)
                    uint count = GetAdditionalLightsCount();
                    for (uint i = 0u; i < count; ++i)
                    {
                        // White shadow mask: this example does not support baked shadow masks.
                        Light light = GetAdditionalLight(i, input.positionWS, half4(1,1,1,1));
                        color += EvaluateOneLight(material, N, V, light);
                    }
                #endif

                color = MixFog(color, input.fogFactor);
                return float4(color, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
```

本示例没有 `ShadowCaster` Pass，因此物体能接收实时阴影，**不会投射阴影**。也没有 `DepthOnly` / `DepthNormals` / `Meta` Pass；依赖这些 Pass 的渲染功能和烘焙流程不在示例范围内。主光阴影演示使用 shadow map / cascade 变体，不包含屏幕空间主光阴影功能。

## 和 URP 原生实现的关系

URP 原生光照会把材质数据预计算为 `BRDFData`，并对镜面公式做性能与精度优化。配套库保持 `D*F*V` 的清晰结构，漫反射用角度相关的 `(1-F)` 权重；不要假定这与原生 `DirectBRDFSpecular` / `LightingPhysicallyBased` 在数值上相同。

主光和附加光接口可对照 [URP 14 官方光照方法](https://docs.unity3d.com/Packages/com.unity.render-pipelines.universal@14.0/manual/use-built-in-shader-methods-lighting.html)。Forward+ 的附加方向光与聚类灯光需要对应的遍历逻辑，普通 `GetAdditionalLightsCount()` 循环不足以覆盖；升级时先检查 [RealtimeLights.hlsl](https://github.com/Unity-Technologies/Graphics/blob/2022.3/staging/Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl)。

## 调试步骤

1. 暂时关雾与后处理，固定曝光；先确认 Base Color、N、L、V。
2. 单独观察 `NoL`，背光一侧应为黑。
3. 用 `CPBR_EvaluateBRDF` 分开输出 diffuse 与 specular。
4. 分别观察 D、F 和 G。D 可能很大，调试显示时可以用 `D/(1+D)` 压缩；不要把这种压缩写进实际 BRDF。
5. 对照 [03 的手算检查点](03_Cook_Torrance_DFG.md#8-手算检查点)，先验证单位方向和单位光。
6. 最后开启阴影和附加光，再逐项增加贴图与间接光。

| 症状 | 优先检查 |
| --- | --- |
| 高光跟着相机奇怪地反向移动 | V/L 方向是否反了，坐标空间是否混用 |
| 高光过宽或过窄 | r、α、α² 是否平方错误，smoothness 是否转成 roughness |
| 掠射出现黑边或爆亮 | NoV/NoL、退化 H、V 与 G 是否重复使用 |
| 金属整体很黑 | 是否缺少 IBL，当前朝向是否没有直接镜面贡献 |
| 离灯近时亮度不对 | 是否重复距离衰减，是否把距离衰减夹到 1 |
| 整体偏灰、偏亮 | 颜色空间、重复 Gamma、曝光、重复除 π |
| 附加光消失 | Renderer 是否为 Forward，是否启用 Per Pixel，变体是否保留 |
| 自己不投影 | 示例未实现 ShadowCaster Pass |

## 验证范围

独立 HLSL 经过 D3DCompile `ps_5_0` / `cs_5_0` 语法编译；数值检查覆盖正视手算、Fresnel 端点、G/V 等价性、互易性、纯金属无漫反射和背面输入。该检查不等于 Unity 导入验证。上面的 ShaderLab 接入代码尚未在 Unity Editor 中编译、运行或做图像比较，应在目标 URP 项目中完成验证。
