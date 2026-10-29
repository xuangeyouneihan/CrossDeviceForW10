# CrossDeviceForW10

在 **Windows 10（build 19041 及以上，含 IoT 企业版 LTSC 2021）** 上安装「跨设备体验主机」（Cross Device Experience Host，`MicrosoftWindows.CrossDevice`），而不是被商店拒绝。

[English version below](#english)

> **免责声明。** 这是一个独立的非官方工具，与 Microsoft Corporation 无任何关联，未获其认可或赞助。「Windows」「Cross Device Experience Host」等为 Microsoft Corporation 的商标。**本仓库不包含、也永远不会包含任何 Microsoft 的二进制文件。** 脚本只修改你自己合法获得的安装包，且所有修改都发生在你的本机。

## 由来

本仓库 fork 自 [b3s3da/AppleMusicForW10](https://github.com/b3s3da/AppleMusicForW10)。

上游解决的是同一类问题：Apple Music 的 Windows 版在清单里要求 Windows 11，把一台完全够用的 Windows 10 挡在门外。它把这类门槛追到了根上——**门槛写在清单里，并不真的缺能力**——并据此写出一个只改清单、不碰二进制的最小方案。

「跨设备体验主机只支持 Windows 10 22H2、在 LTSC 2021 的 21H2 上装不上」这件事困扰了我很久。中途也试过用 22H2 启用包（`KB5015684`）把系统推到 19045 来绕过，结果发现那会让 LTSC 掉进消费版的停更分支（2025-10 已终止支持），而 IoT 企业版 LTSC 2021 可以支持到 2032 年，于是又退了回来。

既然上游的思路值得借鉴，就索性照它的方法论把这一例也验证到底：先确认门槛的性质，再确认需要改动的最小集合。

需要说明的是，代码不是我自己写的。整个过程中我只负责提需求、实际测试和判断取舍，脚本与文档由 AI 助手（DeepSeek）生成。实测环境为 Windows 10 IoT 企业版 LTSC 2021（`10.0.19044.7807`）。

上游的 `LICENSE` 与版权声明一并保留，详见 [`LICENSE`](LICENSE)。

## 为什么需要它

「跨设备体验主机」是 Windows 与 Android 手机对接的组件，承担「手机连接」（Phone Link）的部分能力。微软商店为其声明的最低系统版本是：

```xml
<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19045.0" ... />
```

`10.0.19045.0` 是 **Windows 10 22H2**。于是所有 build 19044 的系统——包括 Windows 10 IoT 企业版 LTSC 2021——在商店里都装不上它。

**但这个门槛是清单声明，不是技术依赖。** 包自身的运行时版本检查为：

```csharp
// CrossDevice.Core!IsUnsupportedReleaseVersion
IsApiContractPresent("Windows.Foundation.UniversalApiContract", 10)
```

即只要求 build 19041（Windows 10 2004）。19044 与 19045 共享同一套内核与 Win32/WinRT API 面，19044 完全满足这个条件。换句话说，`19045` 这个数字描述的是「微软测试过 22H2」，而非「需要 22H2 才有的能力」。

详情见 [`docs/root-cause-analysis.md`](docs/root-cause-analysis.md)。

## 系统侧其实是就绪的

这一点容易被误解，值得单独说明：Windows 10 19044 自己**已经内置**了对接这套组件的代码。`C:\Windows\System32\SettingsHandlers_ManagePhone.dll`（「移动设备」设置页的处理器）中包含：

```
shellcommon\shell\settingshandlers\managephone\lib\crossdeviceinstallingsetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\opencrossdevicesetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\enablecrossdevicesetting.cpp

SystemSettings_Device_Phone_CrossDeviceEnabled_DialogToggle
SystemSettings_Device_Phone_CrossDeviceInstalling
SystemSettings_Device_Phone_OpenCrossDevice
ms-crossdevice-settings:?scenarioId=Settings
MicrosoftWindows.CrossDevice_8wekyb3d8bbwe      ← 商店发布者哈希
MicrosoftWindows.CrossDevice_cw5n1h2txyewy      ← 内置发布者哈希
```

也就是说系统认识这个包、知道怎么打开它、也认识它的两种发布者身份。缺的只是「让包被注册进去」这一步。

## 仓库内容

| 路径 | 说明 |
|---|---|
| `install.ps1` | 一键安装器：定位或解析安装包 → 解包 → 改清单 → 注册 |
| `docs/root-cause-analysis.md` | 门槛成因的完整分析与实测记录 |
| `LICENSE` | MIT |

仓库中**不含**任何 `.msix` / `.appxbundle` / `.cab`。

## 用法

在**普通（非提权）的 Windows PowerShell 5.1** 窗口中运行。PowerShell 7 不行——`Appx` 模块在 pwsh 下不可用。

### 前提

需要在「设置 → 更新和安全 → 开发者选项」中启用**开发人员模式**（或「旁加载应用」）。脚本会检查，未启用时给出开启命令。

### 一键快速安装（推荐）

```powershell
irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 | iex
```

这一条命令会下载安装器并立即执行。

如果你当前在 **PowerShell 7** 里，`iex` 会因为 `Appx` 模块不可用而中止。改用下面的形式（从 PowerShell 7 或 cmd 都能启动 5.1）：

```powershell
powershell -NoProfile -Command "irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 | iex"
```

**`iex` 方式无法传参数**，因此它只在下列位置查找安装包：

- 当前工作目录
- `%USERPROFILE%\Downloads`

需要指定包路径、改安装位置、或安装后自动打开设置页时，请用下一节的方式。

> 注意：这条命令下载的是**脚本**，不是安装包。安装包需要你自己准备（原因见 [不提供安装包](#不提供安装包)）。如果上述两个位置都没有可用的包，脚本会列出它找到的每个候选以及跳过原因。

### 指定安装包运行

先把脚本存到本地，再带参数运行（能力最完整）：

```powershell
irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 -OutFile install.ps1

# 自动在脚本所在目录、上级目录、当前目录、Downloads 中寻找可用于 Windows 10 的包
.\install.ps1

# 显式指定包（推荐）
.\install.ps1 -BundlePath '.\MicrosoftWindows.CrossDevice_1.25072.59.0_neutral_~_cw5n1h2txyewy.AppxBundle'

# 装好之后直接打开设置页
.\install.ps1 -BundlePath '...' -Launch
```

### 参数

| 参数 | 说明 |
|---|---|
| `-BundlePath` | `.AppxBundle` / `.msixbundle` / 已解包的目录 / 单个 `.msix` |
| `-InstallDir` | 安装位置，默认 `%LOCALAPPDATA%\Programs\CrossDevice` |
| `-MinOs` | 写入清单的 `MinVersion`，默认 `10.0.19041.0` |
| `-Launch` | 安装后打开 `ms-crossdevice-settings:?scenarioId=Settings` |
| `-PreferOnline` | 先尝试从微软交付服务器解析最新版 |
| `-SkipDependencyCheck` | 依赖不满足时仍然继续 |
| `-Uninstall` | 注销包并删除安装目录 |
| `-KeepData` | 与 `-Uninstall` 合用，保留每用户数据（设置项） |

### 卸载

```powershell
.\install.ps1 -Uninstall            # 连数据一起清除
.\install.ps1 -Uninstall -KeepData  # 保留「允许访问移动设备」等设置
```

## 脚本做了什么

1. **定位安装包。** 给定 `-BundlePath` 就用它；否则在常见位置搜索，并**逐个解出内层 `.msix` 读取真实的 `TargetDeviceFamily`**。这一点很关键：同一个目录里往往放着多个版本，其中大部分只面向 Windows 11（见下表），脚本会跳过它们并说明原因。
2. **解包。** 从 bundle 清单里挑 x64 应用程序包。注意必须排除 `AppxMetadata\Stub\` 下的 stub 条目——它们同样是 `Type="application"`，版本形如 `0.x`，里面没有真实载荷。
3. **改清单。** 把 `MinVersion="10.0.19045.0"` 改为 `-MinOs` 指定的值（默认 `10.0.19041.0`）。
4. **移除签名元数据。** 删除 `AppxSignature.p7x`、`AppxBlockMap.xml`、`[Content_Types].xml`、`AppxMetadata\CodeIntegrity.cat`。它们描述的是修改前的内容，留着会让系统判定包被篡改。
5. **注册。** `Add-AppxPackage -Register <目录>\AppxManifest.xml`，松散注册。
6. **校验。** 查包状态、检查依赖版本。

**不改包名。** 这是本工具与同类方案最重要的区别。包身份保持 `MicrosoftWindows.CrossDevice`（家族名 `_cw5n1h2txyewy`），因为 `YourPhone.Utilities.dll`（手机连接）与 `SettingsHandlers_ManagePhone.dll` 都按这个名字硬编码引用它。改名会让宿主彻底找不到它。

**不打任何二进制补丁。** 包内没有被编译进原生代码的「Windows 11 判断」需要改成恒真——仅有的 `IsNickel22H2Supported` 一类判断要求 `Major == 22621`，在 19044 与 19045 上结果相同，均返回 false，不构成两者之间的差异。

## 已知限制

### 界面是英文的

这是目前唯一实际的功能缺口，成因是部署模型的双重约束：

- **资源包不能在开发模式下注册。** 尝试注册 zh-hans 语言包时 Windows 报 `0x80073CF9`：「在注册框架或资源程序包时，不允许使用 DevelopmentMode」。
- **带签名的原版资源包被同一道门槛拦下。** 用 `Add-AppxPackage -Path` 走正规部署时，语言包自己声明 `MinVersion="10.0.19045.0"`，在 19044 上报 `0x80073CFD`。而一旦为了降版本而修改清单，签名就失效了。

经实测确认这不是缓存或语言设置问题：主包的 `resources.pri` 中检索「移动设备」「设置」「手机」「连接」等词**全部无命中**，而 zh-hans 语言包的 `resources.pri` 中**全部存在**。中文串真的不在主包里。

要中文只能二选一：给整包重新签名并把自签证书装入 `LocalMachine\TrustedPeople`（需要管理员权限，且要接受在本机信任一张冒充 Microsoft 发布者名的证书），或者把系统升到 19045 后用原版语言包。

### 不提供安装包

脚本尝试过两条获取路径：

- **本地搜索**：在你指定的位置及常见目录中查找，并按清单内容校验是否适用于 Windows 10。
- **从微软交付服务器解析**：完整实现了「商店产品 ID → `WuCategoryId` → FE3 SOAP `GetCookie` / `SyncUpdates` / `GetExtendedUpdateInfo2`」这条流程（与 `winget` / Store 客户端同源）。但**目前微软的目录响应不再返回文件清单**——`ExtendedProperties` 中没有 `<Files>` 元素，`GetExtendedUpdateInfo2` 返回空的 `GetExtendedUpdateInfo2Result`。因此这条路目前取不到下载地址。

结论：**需要自备最后一个面向 Windows 10 的构建**（见下表），用 `-BundlePath` 指定。

### 版本选择

本仓库开发与实测围绕 `MicrosoftWindows.CrossDevice` 的以下构建：

| 版本 | `MinVersion` | 目标系统 | 包内架构 | 运行时依赖 |
|---|---|---|---|---|
| 1.24032.58.0 | `10.0.22621.0` | Windows 11 22H2 | arm64 / x64 / x86 | WindowsAppRuntime 1.4 |
| **1.25072.59.0** | **`10.0.19045.0`** | **Windows 10 22H2** | arm64 / x64 / x86 | WindowsAppRuntime 1.7 |
| 1.25092.33.0 | `10.0.22631.0` | Windows 11 23H2 | arm64 / x64 / x86 | WindowsAppRuntime 1.7 |
| 1.26082.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 | WindowsAppRuntime 2.1 |
| 1.26092.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 | WindowsAppRuntime 2.4 |

**只有 `1.25072.59.0` 是面向 Windows 10 的。** 2026 年的两个构建不仅把门槛提到 22631，还砍掉了 x86。脚本会自动识别并跳过其余版本。

### 关于「升到 22H2」

有人用 `KB5015684`（22H2 启用包）把 19044 升到 19045 来绕过门槛。经拆解核实，该包**只写一个注册表开关**、不安装任何文件：

| 组件 | FeatureManagement 覆盖项 |
|---|---|
| 20H2Enablement | `2093230218` |
| 21H1Enablement | `633829003` |
| 21H2Enablement | `2083071627` |
| **22H2Enablement** | **`1987994252`** |

写了 `1987994252`，系统就自称 19045。**系统文件一个都没变**，因此这不会让 CrossDevice 获得任何新能力。对 LTSC 2021 而言还有个代价：19045 走消费版分支（2025-10 已终止支持），而 IoT 企业版 LTSC 2021 支持到 2032-01。

> 另外提醒：网上流传的「LTSC 专用」改版启用包，其 `update.mum` 在签名之后被编辑过（与 Microsoft 签名的 `update.cat` 中的哈希不符），改动内容是把 `EnterpriseS` / `EnterpriseSN` 等从适用清单里去掉/加入。功能载荷文件本身仍是微软原版，但外层不可校验。

## 安全性

- 不触碰 DRM、账号认证或任何联网逻辑。
- 只修改 `AppxManifest.xml` 里 `MinVersion` 这一个属性，以及删除签名元数据。
- 不改包身份、不改任何二进制、不改系统设置。
- 所有改动都在 `-InstallDir` 指向的目录内，`-Uninstall` 可完全回滚。

## 已知的适用性

- 仅 x64。bundle 中的 arm64 包本脚本不处理。
- 需要 build ≥ 19041。低于此版本应用自身也无法运行。
- 需要开发者模式（松散注册的前提）。

## 许可证

MIT。见 [`LICENSE`](LICENSE)。

本仓库为 [b3s3da/AppleMusicForW10](https://github.com/b3s3da/AppleMusicForW10) 的 fork，沿用其 MIT 许可并保留原有版权声明。

---

# English

Install the **Cross Device Experience Host** (`MicrosoftWindows.CrossDevice`) on **Windows 10 (build 19041 or newer, including IoT Enterprise LTSC 2021)** instead of being refused by the Store.

> **Disclaimer.** This is an independent, unofficial tool. It is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. "Windows" and "Cross Device Experience Host" are trademarks of Microsoft Corporation. **This repository contains, and will never contain, any Microsoft binary.** The script only modifies an installer you obtained yourself, and every modification happens on your own machine.

## Origin

This repository is a fork of [b3s3da/AppleMusicForW10](https://github.com/b3s3da/AppleMusicForW10).

Upstream tackles the same class of problem: the Windows build of Apple Music declares Windows 11 in its manifest, shutting out a Windows 10 installation that is perfectly capable of running it. It traced that class of gate to its root — **the gate lives in the manifest, not in a missing capability** — and turned that into a minimal fix that edits the manifest and touches no binary.

The fact that Cross Device Experience Host claims to support only Windows 10 22H2 — and therefore refuses to install on LTSC 2021's 21H2 — had been bothering me for a long time. Along the way I also tried pushing the system to 19045 with the 22H2 enablement package (`KB5015684`), only to find that it moves LTSC onto the consumer support branch (out of support since 2025-10), while IoT Enterprise LTSC 2021 is supported through 2032. So I backed it out.

Since upstream's approach was worth borrowing, I followed its methodology to settle this case too: establish the nature of the gate first, then establish the smallest set of changes required.

To be clear about authorship: I did not write this code myself. I supplied the requirements, ran the tests and made the judgement calls; the script and the documentation were produced by an AI assistant (DeepSeek). The test environment was Windows 10 IoT Enterprise LTSC 2021 (`10.0.19044.7807`).

Upstream's `LICENSE` and copyright notice are retained — see [`LICENSE`](LICENSE).

## Why this exists

Cross Device Experience Host is the component that connects Windows to an Android phone and backs part of the Phone Link experience. Its Store manifest declares:

```xml
<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19045.0" ... />
```

`10.0.19045.0` is Windows 10 22H2, so every build 19044 system — including Windows 10 IoT Enterprise LTSC 2021 — is refused by the Store.

**That gate is a manifest declaration, not a technical dependency.** The package's own runtime check is:

```csharp
// CrossDevice.Core!IsUnsupportedReleaseVersion
IsApiContractPresent("Windows.Foundation.UniversalApiContract", 10)
```

which only requires build 19041 (Windows 10 2004). Builds 19044 and 19045 share the same kernel and the same Win32/WinRT surface, so 19044 satisfies it comfortably. The number `19045` describes what Microsoft tested, not what the app needs.

See [`docs/root-cause-analysis.md`](docs/root-cause-analysis.md) for the full analysis and test log.

## The OS side is already there

This is easy to get wrong, so it deserves its own section. Windows 10 19044 already ships the code that consumes this component. `C:\Windows\System32\SettingsHandlers_ManagePhone.dll` — the handler behind the "Mobile devices" settings page — contains:

```
shellcommon\shell\settingshandlers\managephone\lib\crossdeviceinstallingsetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\opencrossdevicesetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\enablecrossdevicesetting.cpp

SystemSettings_Device_Phone_CrossDeviceEnabled_DialogToggle
SystemSettings_Device_Phone_CrossDeviceInstalling
SystemSettings_Device_Phone_OpenCrossDevice
ms-crossdevice-settings:?scenarioId=Settings
MicrosoftWindows.CrossDevice_8wekyb3d8bbwe      <- Store publisher hash
MicrosoftWindows.CrossDevice_cw5n1h2txyewy      <- Inbox publisher hash
```

The OS knows this package, knows how to open it, and knows both publisher identities. What is missing is only the step that gets the package registered.

## What's in this repo

| Path | What it is |
|---|---|
| `install.ps1` | One-command installer: locate or resolve the package, unpack, patch the manifest, register |
| `docs/root-cause-analysis.md` | Full write-up of the gate and the verification log |
| `LICENSE` | MIT |

No `.msix`, `.appxbundle` or `.cab` is included.

## Usage

Run it in a **normal (non-elevated) Windows PowerShell 5.1** window. PowerShell 7 will not work — the `Appx` module is unavailable there.

### Prerequisite

Enable **Developer Mode** (or "Sideload apps") under Settings > Update & Security > For developers. The script checks this and prints the exact command if it is off.

### One-line install (recommended)

```powershell
irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 | iex
```

This single command downloads the installer and runs it immediately.

If you are currently in **PowerShell 7**, `iex` will stop because the `Appx` module is unavailable. Use this form instead (it starts 5.1 and works from PowerShell 7 or cmd):

```powershell
powershell -NoProfile -Command "irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 | iex"
```

**The `iex` form cannot take parameters**, so it only looks for a bundle in:

- the current working directory
- `%USERPROFILE%\Downloads`

To pass a package path, change the install location, or open the settings page afterwards, use the next section.

> Note: this command downloads the **script**, not the package. You supply the package yourself (see [No downloads are provided](#no-downloads-are-provided)). If neither location holds a usable bundle, the script lists every candidate it found together with the reason it was skipped.

### Running a local copy

Save the script first, then run it with arguments (full capability):

```powershell
irm https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1 -OutFile install.ps1

# Search next to the script, one level up, the current directory, and
# Downloads for a Windows 10 compatible bundle
.\install.ps1

# Point at a specific bundle (recommended)
.\install.ps1 -BundlePath '.\MicrosoftWindows.CrossDevice_1.25072.59.0_neutral_~_cw5n1h2txyewy.AppxBundle'

# Open the settings page afterwards
.\install.ps1 -BundlePath '...' -Launch
```

### Parameters

| Parameter | Meaning |
|---|---|
| `-BundlePath` | `.AppxBundle` / `.msixbundle` / unpacked folder / a single `.msix` |
| `-InstallDir` | Target directory. Default `%LOCALAPPDATA%\Programs\CrossDevice` |
| `-MinOs` | `MinVersion` written into the manifest. Default `10.0.19041.0` |
| `-Launch` | Open `ms-crossdevice-settings:?scenarioId=Settings` when done |
| `-PreferOnline` | Try Microsoft's delivery servers first |
| `-SkipDependencyCheck` | Continue even if a dependency is missing |
| `-Uninstall` | Unregister the package and delete the install directory |
| `-KeepData` | With `-Uninstall`, keep the per-user data folder |

### Uninstall

```powershell
.\install.ps1 -Uninstall            # remove everything
.\install.ps1 -Uninstall -KeepData  # keep the "allow access" toggle and friends
```

## How it works

1. **Locate the package.** Use `-BundlePath` if given, otherwise search common locations and **unpack each candidate far enough to read the real `TargetDeviceFamily`**. This matters: a directory typically holds several builds, most of which are Windows 11 only (see the table), and the script skips them with a reason.
2. **Unpack.** Pick the x64 application package from the bundle manifest. The `AppxMetadata\Stub\` entries must be excluded — they are `Type="application"` too, carry version `0.x`, and hold no payload.
3. **Patch the manifest.** Rewrite `MinVersion="10.0.19045.0"` to the value given by `-MinOs` (default `10.0.19041.0`).
4. **Strip signature metadata.** Delete `AppxSignature.p7x`, `AppxBlockMap.xml`, `[Content_Types].xml` and `AppxMetadata\CodeIntegrity.cat`. They describe the pre-patch contents and would otherwise make Windows treat the package as tampered.
5. **Register.** `Add-AppxPackage -Register <dir>\AppxManifest.xml`.
6. **Verify.** Check package status and dependency versions.

**The package identity is not renamed.** That is the most important difference from similar approaches. It stays `MicrosoftWindows.CrossDevice` (family `_cw5n1h2txyewy`), because both `YourPhone.Utilities.dll` (Phone Link) and `SettingsHandlers_ManagePhone.dll` reference that name literally. Renaming it would make the hosts unable to find it at all.

**No binary is patched.** There is no native `IsMachineWindows11`-style export compiled into the package to force to `true`. The only version-shaped checks, such as `IsNickel22H2Supported`, require `Major == 22621`, so they return the same `false` on 19044 and 19045 and cannot explain any difference between the two.

## Limitations

### The UI is in English

This is the only real functional gap, and it comes from a two-sided constraint in the deployment model:

- **Resource packages cannot be registered in Developer Mode.** Registering the zh-hans language package fails with `0x80073CF9`: "DevelopmentMode is not allowed when registering framework or resource packages."
- **The signed original is blocked by the same gate.** Deploying it properly with `Add-AppxPackage -Path` fails with `0x80073CFD`, because the language package itself declares `MinVersion="10.0.19045.0"`. Editing the manifest to lower it invalidates the signature.

This is not a cache or locale problem: searching the main package's `resources.pri` for "移动设备", "设置", "手机" and "连接" yields **no matches**, while the zh-hans package's `resources.pri` contains them all. The Chinese strings genuinely are not in the main package.

Getting Chinese requires one of: re-signing the whole package with a self-signed certificate trusted in `LocalMachine\TrustedPeople` (admin rights, and trusting a certificate that impersonates Microsoft's publisher name), or moving the system to 19045 and installing the original language packages.

### No downloads are provided

Two acquisition paths exist:

- **Local search** — find and validate candidates by their manifest.
- **Microsoft delivery servers** — the full "Store product id → `WuCategoryId` → FE3 SOAP `GetCookie` / `SyncUpdates` / `GetExtendedUpdateInfo2`" flow used by `winget` and the Store client. However, **Microsoft's catalog response no longer includes a file list**: there is no `<Files>` element in `ExtendedProperties`, and `GetExtendedUpdateInfo2` returns an empty `GetExtendedUpdateInfo2Result`. This path currently yields no URL.

So: **bring the last Windows 10 build yourself** and pass it with `-BundlePath`.

### Which build to use

| Version | `MinVersion` | Target | Architectures | Runtime dependency |
|---|---|---|---|---|
| 1.24032.58.0 | `10.0.22621.0` | Windows 11 22H2 | arm64 / x64 / x86 | WindowsAppRuntime 1.4 |
| **1.25072.59.0** | **`10.0.19045.0`** | **Windows 10 22H2** | arm64 / x64 / x86 | WindowsAppRuntime 1.7 |
| 1.25092.33.0 | `10.0.22631.0` | Windows 11 23H2 | arm64 / x64 / x86 | WindowsAppRuntime 1.7 |
| 1.26082.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 | WindowsAppRuntime 2.1 |
| 1.26092.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 | WindowsAppRuntime 2.4 |

**Only `1.25072.59.0` targets Windows 10.** The two 2026 builds raise the floor to 22631 and drop x86 as well. The script detects and skips the rest.

### About "just upgrade to 22H2"

Some guides use `KB5015684` (the 22H2 enablement package) to turn 19044 into 19045 and clear the gate. Unpacking it confirms that it **writes a single registry flag and installs no files at all**:

| Component | FeatureManagement override |
|---|---|
| 20H2Enablement | `2093230218` |
| 21H1Enablement | `633829003` |
| 21H2Enablement | `2083071627` |
| **22H2Enablement** | **`1987994252`** |

Writing `1987994252` makes the system report 19045. **Not one system file changes**, so this grants CrossDevice no new capability. For LTSC 2021 there is also a cost: 19045 follows the consumer branch (out of support since 2025-10), while IoT Enterprise LTSC 2021 is supported through 2032-01.

> Also worth knowing: the "LTSC-specific" repack circulated online has an `update.mum` that was edited after signing (its hash does not match the Microsoft-signed `update.cat`). The edit adds/removes `EnterpriseS`, `EnterpriseSN` and friends from the applicability list. The payload files themselves are still Microsoft originals, but the outer layer cannot be verified.

## What this does not do

- It does not touch DRM, account authentication, or any network logic.
- It only changes `MinVersion` in `AppxManifest.xml` and deletes signature metadata.
- It does not rename the package, patch any binary, or modify system settings.
- Everything happens inside `-InstallDir`; `-Uninstall` rolls it all back.

## Applicability

- x64 only. The arm64 package inside the bundle is not handled.
- Requires build >= 19041; below that the app itself cannot run.
- Requires Developer Mode (a prerequisite for loose registration).

## License

MIT. See [`LICENSE`](LICENSE).

This repository is a fork of [b3s3da/AppleMusicForW10](https://github.com/b3s3da/AppleMusicForW10); the MIT license and the original copyright notice are retained.