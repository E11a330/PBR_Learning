# 02 · BRDF 模型分类

[返回目录](README.md) · [上一篇](01_PBR_Basics.md) · [下一篇：DFG](03_Cook_Torrance_DFG.md)

## 先分清层级

```text
表面反射 BRDF
├── 漫反射部分
│   ├── Lambert
│   ├── Burley / Disney diffuse
│   └── Oren–Nayar
└── 镜面反射部分
    ├── 经验模型：Phong、Blinn–Phong
    └── 微表面模型：Cook–Torrance 类
        ├── D：GGX、Beckmann 等法线分布
        ├── F：精确 Fresnel、Schlick 近似
        └── G：Smith 等微表面遮蔽模型
```

**GGX 通常指 D 的选择，Cook–Torrance 是镜面 BRDF 的组合框架。**「GGX BRDF」常是对某套完整微表面组合的简称，读代码时还要确认 F 与 G。

## 漫反射模型

### Lambert：最容易对照的基线

$$f_d=\frac{c_d}{\pi}$$

`c_d` 是漫反射反照率；`NoL` 在光照积分外层乘，不在这个 BRDF 内重复乘。

为什么除以 π？常量 BRDF 在半球上按余弦积分，有：

$$\int_{\Omega^+}\frac{c_d}{\pi}\cos\theta\,d\omega=c_d$$

这里是无分层权重的 Lambert。配套代码另外使用 `kD = (1-F)(1-metallic)` 进行近似能量分配。

### Burley / Disney diffuse：加入角度与粗糙度

常见形式为：

$$
f_d=\frac{c_d}{\pi}
[1+(F_{D90}-1)(1-NoL)^5]
[1+(F_{D90}-1)(1-NoV)^5]
$$

$$F_{D90}=0.5+2r(LoH)^2$$

它能表现粗糙漫反射在某些方向的回返增强。这里 r 仍指感知粗糙度，`LoH=dot(L,H)`；`F_D90` 是漫反射经验参数，**不是镜面 F0**。上式是常见的原始角度修正形式，不能仅凭 `/π` 就认定它与任意镜面项组合后严格守恒；不同实现可能附加能量修正。替换这一项也不等于获得完整 Disney 材质。配套 HLSL 选择 Lambert，方便隔离镜面 DFG。

### Oren–Nayar：粗糙漫反射

把漫反射面看作有方向分布的小面片，适合解释粉笔、石膏等粗糙表面的角度变化。其粗糙度常用微面片倾角的标准差表示，不能直接假定等于本笔记的 GGX `α`。

## 镜面模型对照

| 模型 | 核心形状 | 学习重点 |
| --- | --- | --- |
| Phong | `max(R·V,0)^n` | 用反射向量 R 控制经验高光 |
| Blinn–Phong | `max(N·H,0)^n` | 用半角向量简化高光计算 |
| Cook–Torrance 类 | `D F G / (4 NoL NoV)` | 将法线分布、界面反射、微遮蔽拆开 |

经典 Phong / Blinn–Phong 表达式若未归一化，不自动满足能量约束；也存在经过归一化或重新推导的版本，不能只凭名称判断是否物理合理。

这里 `R=reflect(-L,N)`，n 是控制高光锐利度的指数，L/V/N 都是单位方向。n 与 GGX 的 r/alpha 不是同一个参数，不能不做转换就直接互换。

## NDF 的选择

| D 模型 | 典型特点 | 注意事项 |
| --- | --- | --- |
| Beckmann | 高光尾部下降较快 | 对应高斯微表面斜率分布 |
| GGX / Trowbridge–Reitz | 尾部更长 | 常用于实时 PBR 的反射模型 |

`D` 是微表面法线分布，不是贴图法线，也不是最终高光颜色。更换 D 时，要一并检查与之匹配的 G、采样分布和 IBL 预积分。

## 角色材质怎样选

- 普通不透明道具、护甲、塑料：以 Lambert + GGX 作为学习起点。
- 皮肤：界面反射之外，通常需要 SSS 或其他次表面散射近似。
- 头发：方向性很强，通常需要专用纤维散射模型。
- 布料：可能需要绒毛 sheen / 专用织物高光。

先用基础模型验证坐标、颜色空间和光源接口，再逐个增加复杂项，才能知道变化来自哪里。

模型对照入口：[Filament 材质系统](https://google.github.io/filament/main/filament.html#materialsystem)。下一篇将固定模型选择，完整推导 [D/F/G 与 HLSL 的对应](03_Cook_Torrance_DFG.md)。

## BRDF 组合时的接口约定

模型公式返回的是材质响应。Lambert 的 `baseColor/PI` 不含灯色和外层 NoL；Cook–Torrance 也不包含场景阴影。外层光照代码统一应用这些因素，才能正确组合不同反射分量。

更换 Burley 漫反射时，模型内部虽然使用 NoL 参与角度修正，仍需要乘渲染方程外层的投影余弦。这两个 NoL 用途不同，不能因为“函数里已经有了”就删掉外层因子。

GGX 的 D 与相应 G、IBL 预过滤和积分近似需要匹配。替换 D 后保留所有其他计算，并不自动得到自洽的新模型。

本笔记固定使用 Lambert + GGX 微表面镜面反射，后续代码围绕这一组合展开。这样可以先完整理解一套模型，再有依据地比较和替换。
