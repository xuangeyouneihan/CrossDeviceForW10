# 根因分析

[English](#english)

---

## 中文

### 分析对象

| 项目 | 值 |
|---|---|
| 包 | `MicrosoftWindows.CrossDevice`（跨设备体验主机） |
| 版本 | `1.25072.59.0`（bundle 内 x64 应用包） |
| 发布者 | `CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` |
| 测试系统 | Windows 10 IoT 企业版 LTSC 2021，`10.0.19044.7807`，x64 |
| 结论 | 门槛在清单，不在 API |

方法：解包 `.AppxBundle` / `.msix`、比对 `AppxManifest.xml`、用 `dnfile` 反编译托管程序集的 IL、扫描注册表与 `System32` 字符串、实际部署并观察事件日志。

### 结论速览

商店声明的最低版本是 `10.0.19045.0`（Windows 10 22H2）。这**不是一个真实的能力要求**，而是一句「微软在 22H2 上测过」的声明。包自身在运行时只要求 `Windows.Foundation.UniversalApiContract` v10，即 build 19041。因此把 `MinVersion` 降到 19041 即可在 19044 上安装并正常工作。

---

### 证据一：门槛写在清单里

`1.25072.59.0` 的 x64 包，`AppxManifest.xml`：

```xml
<Identity Name="MicrosoftWindows.CrossDevice"
          Publisher="CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
          Version="1.25072.59.0" ProcessorArchitecture="x64"/>

<Dependencies>
  <TargetDeviceFamily Name="Windows.Desktop"
                      MinVersion="10.0.19045.0"
                      MaxVersionTested="10.0.26100.0"/>
  <PackageDependency Name="Microsoft.VCLibs.140.00.UWPDesktop" MinVersion="14.0.33728.0" .../>
  <PackageDependency Name="Microsoft.WindowsAppRuntime.1.7" MinVersion="7000.498.2246.0" .../>
</Dependencies>
```

`AppXDeploymentServer` 在部署时校验 `MinVersion`，不满足即以 `0x80073CFD` 拒绝。这是**安装期**的门槛，与应用实际调用了哪些 API 无关。

各版本的实际声明（决定了哪个包能用）：

| 版本 | `MinVersion` | 目标系统 | 架构 |
|---|---|---|---|
| 1.24032.58.0 | `10.0.22621.0` | Windows 11 22H2 | arm64 / x64 / x86 |
| **1.25072.59.0** | **`10.0.19045.0`** | **Windows 10 22H2** | arm64 / x64 / x86 |
| 1.25092.33.0 | `10.0.22631.0` | Windows 11 23H2 | arm64 / x64 / x86 |
| 1.26082.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 |
| 1.26092.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 |

### 证据二：应用自身的版本检查只要求 19041

`CrossDevice.Core.dll` 是托管程序集（有 COR20 头与 `BSJB` 元数据）。其中唯一一个真正判断「系统是否受支持」的方法：

```
CrossDevice.Core!IsUnsupportedReleaseVersion
IL: 72 D9 0D 00 70   1F 0A   28 49 01 00 0A   16   FE 01   2A
```

| 字节 | 指令 | 含义 |
|---|---|---|
| `72 D9 0D 00 70` | `ldstr` | `"Windows.Foundation.UniversalApiContract"` |
| `1F 0A` | `ldc.i4.s 10` | 版本 10 |
| `28 49 01 00 0A` | `call` | `Windows.Foundation.Metadata.ApiInformation::IsApiContractPresent` |
| `16` / `FE 01` / `2A` | `ldc.i4.0` / `ceq` / `ret` | 返回「契约是否**不**存在」 |

即 `IsUnsupportedReleaseVersion() == !IsApiContractPresent(UniversalApiContract, 10)`。

`UniversalApiContract` v10 对应 **build 19041**（Windows 10 2004）。所以应用自己认为 19041 起就受支持——比清单声明的 19045 低三个版本。

这是整个分析的核心：**把 `MinVersion` 降到 19041 不是「绕过检查」，而是与应用自身的判断对齐。**

### 证据三：几个「看着像 Windows 11 门槛」的判断不构成差异

`CrossDevice.Files.dll` 中存在带 Win11 开发代号的判断：

| 方法 | 条件 |
|---|---|
| `IsNickel22H2Supported` | `Major == 22621 && Version >= 22621.3672` |
| `IsNickel23H2Supported` | 23H2（22631） |
| `IsNickelBetaWipSupported` | Beta/WIP 分支 |

`IsNickel22H2Supported` 的 IL：

```
call     SharedUtilities.WindowsVersion::get_Current
callvirt ::get_Major
ldc.i4   22621
bne.un.s -> ldc.i4.0 / ret        ; Major != 22621 直接 false
call     get_Current
ldc.i4   22621 ; ldc.i4 3672 ; newobj Version::.ctor
call     op_GreaterThanOrEqual
ret
```

这里第一位是 `Major == 22621`。注意 `Version.Major` 对 build 19044 返回 **19044**、对 19045 返回 **19045**——**两者都不是 22621**，所以返回值完全相同（`false`）。

因此这些判断无法解释「19045 能跑、19044 不能跑」。它们的调用方是 `IsPhoneIconSupportedInOs`（资源管理器里的手机图标），属于外观特性。

> 这一点是判断「改清单够不够」的关键分水岭。如果包内有 `IsMachineWindows11` 那样被编译进原生代码、恒定返回 `true` 的补丁点，就必须做二进制修补；这里没有。

### 证据四：系统侧的对接代码本来就在

`C:\Windows\System32\SettingsHandlers_ManagePhone.dll`（「移动设备」设置页的处理器）包含完整的 CrossDevice 集成：

```
shellcommon\shell\settingshandlers\managephone\lib\crossdeviceinstallingsetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\opencrossdevicesetting.cpp
shellcommon\shell\settingshandlers\managephone\lib\enablecrossdevicesetting.cpp

SystemSettings_Device_Phone_CrossDeviceEnabled_DialogToggle
SystemSettings_Device_Phone_CrossDeviceEnabled_NonDialogToggle
SystemSettings_Device_Phone_CrossDeviceInstalling
SystemSettings_Device_Phone_OpenCrossDevice
SystemSettings_Phone_CrossDevice
SettingsPage_Devices_CrossDevice_InstallCrossDeviceDialog_Title
MobileDevicesMainSettingsPage / AllowCrossDeviceToggle / CrossDeviceEnabled

ms-crossdevice-settings:?scenarioId=Settings
MicrosoftWindows.CrossDevice_8wekyb3d8bbwe      ← 商店发布者哈希
MicrosoftWindows.CrossDevice_cw5n1h2txyewy      ← 内置发布者哈希
```

这否定了「Windows 10 缺组件所以装不了」的猜测。系统认识这个包、知道怎么打开它、连两种发布者身份都写进去了。缺的只是「让包被注册」这一步。

### 证据五：不能改包名

包的 `Identity Name` 必须保持 `MicrosoftWindows.CrossDevice`：

- `YourPhone.Utilities.dll`（手机连接）按该名字引用它；
- `SettingsHandlers_ManagePhone.dll` 同时硬编码了包名与两个发布者哈希。

改名会让宿主找不到它，`ms-crossdevice-settings:` 也就无法解析到应用。这与某些同类方案（改包名以规避 Windows 的 StateRepository 残留记录）做法相反，原因是本场景的消费者按名字查找。

本机实测也说明不需要改名：全新系统上 `StateRepository` 没有该包的残留行，不存在需要绕开的坏记录。

### 证据六：语言资源的部署死结

界面语言是唯一实际缺口。实测三条路都被堵死：

| 尝试 | 结果 |
|---|---|
| `Add-AppxPackage -Register <zh-hans>` | `0x80073CF9` —「在注册框架或资源程序包时，不允许使用 DevelopmentMode」 |
| `Add-AppxPackage -Register <zh-hans> -DisableDevelopmentMode` | `0x80073CF9` —「部件清单未位于程序包根目录中」 |
| `Add-AppxPackage -Path <原始签名 zh-hans.msix>` | `0x80073CFD` — 该资源包自身声明 `MinVersion="10.0.19045.0"` |

根因是资源包只能走正规部署，而正规部署既要求签名有效、又校验 `MinVersion`。为降版本而改清单必然破坏签名，保持签名则被 19045 拦住。

并已确认这不是缓存或区域设置问题：

| 检索词 | 主包 `resources.pri` | zh-hans `resources.pri` |
|---|---|---|
| 移动设备 | 无 | 有 |
| 设置 | 无 | 有 |
| 手机 | 无 | 有 |
| 连接 | 无 | 有 |

中文串确实不在主包里，必须依赖语言资源包。

### 证据七：启用包不安装任何文件

`KB5015684`（22H2 启用包）解包后共 20 个文件，其中 4 个「启用组件」的 manifest **只声明注册表写入**，没有任何文件载荷：

| 组件 | FeatureManagement 覆盖项 |
|---|---|
| `Microsoft-Windows-20H2Enablement` | `2093230218` |
| `Microsoft-Windows-21H1Enablement` | `633829003` |
| `Microsoft-Windows-21H2Enablement` | `2083071627` |
| `Microsoft-Windows-22H2Enablement` | `1987994252` |

全部写到 `HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\0\<id>`，`EnabledState = 2`。本机实测：`2083071627 = 2`（所以当前报 19044），`1987994252` 不存在（所以不是 19045）。

**这意味着「升到 19045」只是让系统自称 19045，系统文件一个都没变。** 因此升级不可能让 CrossDevice 获得任何新能力——它对本问题的唯一作用是让商店/部署器的版本校验通过。

顺带核实了网上流传的「LTSC 专用」改版的改动位置。与微软官方 MSU（`windows10.0-kb5015684-x64`，Authenticode 有效）逐字节比对：

| 文件 | 结果 |
|---|---|
| `update.mum` | **不同**（官方 4,594 字节 → 改版 5,396 字节） |
| 其余 19 个（含 5 个 `.cat`） | 字节级完全相同 |

差异仅为在 `<parent>` 适用清单中**新增** 4 行：

```xml
+ Microsoft-Windows-EnterpriseSEdition
+ Microsoft-Windows-EnterpriseSEvalEdition
+ Microsoft-Windows-EnterpriseSNEdition
+ Microsoft-Windows-EnterpriseSNEvalEdition
```

即把 LTSC（`EnterpriseS` / `EnterpriseSN`）系列从排除名单里放回来。没有删除任何行，其余字段（版本号、时间戳、`packageSize`、`installerAssembly`）完全一致。功能载荷仍是微软原版，但外层 `update.mum` 不再被微软 `update.cat` 覆盖，无法校验。

### 实测记录

在 Windows 10 IoT 企业版 LTSC 2021（19044.7807）上：

| 步骤 | 结果 |
|---|---|
| 清单降 `MinVersion` 到 `10.0.19041.0`，删签名元数据 | — |
| `Add-AppxPackage -Register` | 成功，`Status = Ok`，`SignatureKind = None` |
| 注册身份 | `MicrosoftWindows.CrossDevice_1.25072.59.0_x64__cw5n1h2txyewy`（原名） |
| 依赖 | VCLibs `14.0.33728.0`、WindowsAppRuntime 1.7 `7000.785.2325.0`，均满足 |
| `ms-crossdevice-settings:?scenarioId=Settings` | 拉起 `CrossDeviceSettingsHost` + `SystemSettings` |
| 功能 | 「允许此电脑访问你的移动设备」开关可用；「管理设备」按钮可用；管理窗口可打开 |
| 界面语言 | 英文（见证据六） |

### 一个待解释的观察

包的 `appExtension`（`com.microsoft.windows.extension.connecteddevicesexperience`，GUID `34057DFB-FC7C-4476-9AB7-F20D5165945F`）声明了 API 契约 `WindowsUdk.System.ConnectedDevices.ConnectedDevicesContract,1,0`。

在本机 19044 上：注册表 `HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId` 共 4081 项，**没有任何 `WindowsUdk.System.ConnectedDevices.*`**；`System32` 全盘（4,253 个文件 / 2,280 MB）也搜不到该扩展的提供方实现；`WinMetadata` 目录中没有对应 `.winmd`。

然而上面「实测记录」显示功能可用。因此结论是：**核心路径并不依赖这些激活类是否注册**，可能由 `WindowsUdk.dll` 这一托管投影在包内自行解析。此点未进一步验证，本文件不作断言。

### 安全性

- 不触碰 DRM、Microsoft 账号认证或任何联网逻辑。
- 只修改 `AppxManifest.xml` 中 `MinVersion` 一个属性，并删除描述修改前内容的签名元数据。
- 不改包身份、不改任何二进制、不改系统设置。
- 全部改动位于 `-InstallDir` 指向的目录内，`-Uninstall` 可完整回滚。

### 方法论上的两个坑

记录在此以免重复：

1. **用 `IApplicationActivationManager::ActivateApplication` 直接启动 `!App` / `!SettingsUXHostApp` 不能作为功能验证。** 这些是 COM 服务端，被启动后立即退出（实测 45–270 ms，退出码 0，无 WER、无崩溃）属于正常行为。对照组：官方支持的手机连接 `!App` 同样在 190 ms 退出。
2. **不注册的 WinRT 激活类不等于功能不可用。** 见上文「一个待解释的观察」。仅凭注册表缺失就断言「无法运行」是过早结论。

正确的验证路径是走真实入口（`ms-crossdevice-settings:?scenarioId=Settings`）或直接在设置页里操作。

---

# English

### Target

| Item | Value |
|---|---|
| Package | `MicrosoftWindows.CrossDevice` (Cross Device Experience Host) |
| Version | `1.25072.59.0` (x64 application package inside the bundle) |
| Publisher | `CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` |
| Test system | Windows 10 IoT Enterprise LTSC 2021, `10.0.19044.7807`, x64 |
| Conclusion | The gate is in the manifest, not in the API |

Method: unpacked `.AppxBundle` / `.msix`, compared `AppxManifest.xml`, disassembled managed IL with `dnfile`, scanned the registry and `System32` strings, then deployed and observed the event logs.

### Summary

The Store declares `MinVersion="10.0.19045.0"` (Windows 10 22H2). That is **not a capability requirement** — it states that Microsoft tested on 22H2. At runtime the package only needs `Windows.Foundation.UniversalApiContract` v10, which is build 19041. Lowering `MinVersion` to 19041 therefore aligns the installer with the app's own opinion, and the package works on 19044.

### Evidence 1: the gate is a manifest declaration

```xml
<TargetDeviceFamily Name="Windows.Desktop"
                    MinVersion="10.0.19045.0"
                    MaxVersionTested="10.0.26100.0"/>
```

`AppXDeploymentServer` validates `MinVersion` at deploy time and refuses with `0x80073CFD`. This is an **install-time** gate and has nothing to do with which APIs the app calls.

Declared floors per build (which decides what is usable):

| Version | `MinVersion` | Target | Architectures |
|---|---|---|---|
| 1.24032.58.0 | `10.0.22621.0` | Windows 11 22H2 | arm64 / x64 / x86 |
| **1.25072.59.0** | **`10.0.19045.0`** | **Windows 10 22H2** | arm64 / x64 / x86 |
| 1.25092.33.0 | `10.0.22631.0` | Windows 11 23H2 | arm64 / x64 / x86 |
| 1.26082.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 |
| 1.26092.74.0 | `10.0.22631.0` | Windows 11 23H2 | x64 / arm64 |

### Evidence 2: the app's own check only requires 19041

`CrossDevice.Core.dll` is managed (COR20 header, `BSJB` metadata). Its only real "is this OS supported" method:

```
CrossDevice.Core!IsUnsupportedReleaseVersion
IL: 72 D9 0D 00 70   1F 0A   28 49 01 00 0A   16   FE 01   2A
```

| Bytes | Instruction | Meaning |
|---|---|---|
| `72 D9 0D 00 70` | `ldstr` | `"Windows.Foundation.UniversalApiContract"` |
| `1F 0A` | `ldc.i4.s 10` | version 10 |
| `28 49 01 00 0A` | `call` | `ApiInformation::IsApiContractPresent` |
| `16` / `FE 01` / `2A` | `ldc.i4.0` / `ceq` / `ret` | return "is the contract **absent**" |

So `IsUnsupportedReleaseVersion() == !IsApiContractPresent(UniversalApiContract, 10)`.

Contract v10 maps to **build 19041** (Windows 10 2004). The app therefore considers itself supported from 19041 — three builds below the manifest's claim. Lowering `MinVersion` to 19041 is not "bypassing a check"; it is agreeing with the app.

### Evidence 3: the version-flavoured checks explain nothing

`CrossDevice.Files.dll` contains Windows 11 codename checks:

| Method | Condition |
|---|---|
| `IsNickel22H2Supported` | `Major == 22621 && Version >= 22621.3672` |
| `IsNickel23H2Supported` | 23H2 (22631) |
| `IsNickelBetaWipSupported` | Beta/WIP branch |

IL for `IsNickel22H2Supported`:

```
call     SharedUtilities.WindowsVersion::get_Current
callvirt ::get_Major
ldc.i4   22621
bne.un.s -> ldc.i4.0 / ret        ; Major != 22621 -> false
call     get_Current
ldc.i4   22621 ; ldc.i4 3672 ; newobj Version::.ctor
call     op_GreaterThanOrEqual
ret
```

The first test is `Major == 22621`. `Version.Major` is **19044** on 19044 and **19045** on 19045 — **neither is 22621** — so both return the same `false`. These checks cannot explain any behavioural difference between the two builds. Their caller is `IsPhoneIconSupportedInOs`, an Explorer cosmetic feature.

> This is the dividing line for whether a manifest edit suffices. If the package contained a native `IsMachineWindows11`-style patch site, binary patching would be required. It does not.

### Evidence 4: the OS-side integration already exists

`C:\Windows\System32\SettingsHandlers_ManagePhone.dll` (the handler behind the "Mobile devices" page) contains the full integration:

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

This rules out "Windows 10 lacks the component". The OS knows the package, knows how to open it, and knows both publisher identities. Only registration is missing.

### Evidence 5: the identity must not be renamed

`Identity Name` must stay `MicrosoftWindows.CrossDevice`:

- `YourPhone.Utilities.dll` (Phone Link) references it by that name;
- `SettingsHandlers_ManagePhone.dll` hardcodes the name and both publisher hashes.

Renaming makes the hosts unable to find it, and `ms-crossdevice-settings:` can no longer resolve. This is the opposite of some similar projects that rename to dodge a stale StateRepository record — here the consumer looks the package up **by name**.

A fresh system also has no `StateRepository` row for this package, so there is no bad record to dodge in the first place.

### Evidence 6: the resource-package deadlock

UI language is the only real gap. All three routes fail:

| Attempt | Result |
|---|---|
| `Add-AppxPackage -Register <zh-hans>` | `0x80073CF9` — "DevelopmentMode is not allowed when registering framework or resource packages" |
| `Add-AppxPackage -Register <zh-hans> -DisableDevelopmentMode` | `0x80073CF9` — "manifest is not in the package root" |
| `Add-AppxPackage -Path <signed zh-hans.msix>` | `0x80073CFD` — the resource package itself declares `MinVersion="10.0.19045.0"` |

The root cause: resource packages can only be deployed properly, and proper deployment requires both a valid signature and a satisfied `MinVersion`. Editing the manifest to lower the floor breaks the signature; keeping the signature hits the 19045 gate.

Confirmed not to be a cache or locale issue:

| Search term | main `resources.pri` | zh-hans `resources.pri` |
|---|---|---|
| 移动设备 | absent | present |
| 设置 | absent | present |
| 手机 | absent | present |
| 连接 | absent | present |

The Chinese strings genuinely are not in the main package.

### Evidence 7: the enablement package installs no files

`KB5015684` (the 22H2 enablement package) unpacks to 20 files. Four "enablement" component manifests **only declare registry writes**; there is no file payload:

| Component | FeatureManagement override |
|---|---|
| `Microsoft-Windows-20H2Enablement` | `2093230218` |
| `Microsoft-Windows-21H1Enablement` | `633829003` |
| `Microsoft-Windows-21H2Enablement` | `2083071627` |
| `Microsoft-Windows-22H2Enablement` | `1987994252` |

Each writes `HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\0\<id>` with `EnabledState = 2`. On the test machine: `2083071627 = 2` (hence 19044), `1987994252` absent (hence not 19045).

**So "upgrading to 19045" only changes what the system reports; not a single system file changes.** It cannot give CrossDevice any new capability — its only effect on this problem is satisfying a version check in the deployer/Store.

The "LTSC repack" circulating online was also checked. Compared byte-by-byte against the official Microsoft MSU (`windows10.0-kb5015684-x64`, valid Authenticode):

| File | Result |
|---|---|
| `update.mum` | **differs** (official 4,594 bytes → repack 5,396 bytes) |
| the other 19 (including 5 `.cat`) | byte-identical |

The difference is 4 **added** lines in the `<parent>` applicability list:

```xml
+ Microsoft-Windows-EnterpriseSEdition
+ Microsoft-Windows-EnterpriseSEvalEdition
+ Microsoft-Windows-EnterpriseSNEdition
+ Microsoft-Windows-EnterpriseSNEvalEdition
```

i.e. LTSC (`EnterpriseS` / `EnterpriseSN`) is put back into the applicable set. Nothing was removed and every other field (version, timestamps, `packageSize`, `installerAssembly`) is identical. The payload is still Microsoft original, but the outer `update.mum` is no longer covered by Microsoft's `update.cat` and cannot be verified.

### Test log

On Windows 10 IoT Enterprise LTSC 2021 (19044.7807):

| Step | Result |
|---|---|
| `MinVersion` lowered to `10.0.19041.0`, signature metadata removed | — |
| `Add-AppxPackage -Register` | succeeded, `Status = Ok`, `SignatureKind = None` |
| Registered identity | `MicrosoftWindows.CrossDevice_1.25072.59.0_x64__cw5n1h2txyewy` (original name) |
| Dependencies | VCLibs `14.0.33728.0`, WindowsAppRuntime 1.7 `7000.785.2325.0`, both satisfied |
| `ms-crossdevice-settings:?scenarioId=Settings` | spawns `CrossDeviceSettingsHost` + `SystemSettings` |
| Functionality | "Allow this PC to access your mobile devices" toggle works; "Manage devices" enabled; window opens |
| UI language | English (see Evidence 6) |

### An unexplained observation

The package's `appExtension` (`com.microsoft.windows.extension.connecteddevicesexperience`, GUID `34057DFB-FC7C-4476-9AB7-F20D5165945F`) declares the API contract `WindowsUdk.System.ConnectedDevices.ConnectedDevicesContract,1,0`.

On the test 19044 machine: the registry key `HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId` has 4081 entries and **none is `WindowsUdk.System.ConnectedDevices.*`**; a full `System32` scan (4,253 files / 2,280 MB) finds no provider for the extension; and `WinMetadata` has no matching `.winmd`.

Yet the test log above shows the feature works. The reasonable conclusion is that **the core path does not depend on those activatable classes being registered**, and may resolve through the in-package managed `WindowsUdk.dll` projection. This was not investigated further and is not asserted here.

### Safety

- No DRM, Microsoft account authentication, or network logic is touched.
- Only the `MinVersion` attribute in `AppxManifest.xml` is changed, plus removal of signature metadata that describes the pre-patch contents.
- No identity change, no binary patch, no system setting change.
- Everything lives inside `-InstallDir`; `-Uninstall` fully rolls back.

### Two methodological traps

Recorded so they are not repeated:

1. **`IApplicationActivationManager::ActivateApplication` on `!App` / `!SettingsUXHostApp` is not a functional test.** These are COM servers; exiting immediately after launch (measured 45–270 ms, exit code 0, no WER, no crash) is normal. Control: the officially supported Phone Link `!App` also exits after 190 ms.
2. **A missing WinRT activatable class does not imply the feature is broken.** See "An unexplained observation". Concluding "it cannot run" from a registry absence alone is premature.

The correct verification path is the real entry point (`ms-crossdevice-settings:?scenarioId=Settings`) or operating the Settings page directly.