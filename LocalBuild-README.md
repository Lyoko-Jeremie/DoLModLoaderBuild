# 本地 Windows 构建（复刻 GitHub Actions 工作流）

本目录下的脚本可以在**本地 Windows 10/11 电脑**上完整复刻
[`.github/workflows/Build-Html-Package.yml`](.github/workflows/Build-Html-Package.yml)
（`Build ModLoader`）的构建流程，产出与 CI **完全一致**的发布包，
不需要 GitHub Actions、不需要服务器。

---

## 1. 快速开始

```shell
# 完整构建（会自动拉取子模块、安装依赖、编译、注入、打包）
.\Build-ModLoader-Local.ps1
```

也可以直接**双击** `Build-ModLoader-Local.bat` 一键构建（内含 `pause`，结束后不会闪退）。

> **执行策略报错？** 若提示 `无法加载文件，因为在此系统上禁止运行脚本`，
> 请先执行一次：
> ```shell 
> Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
> ```
> （或直接运行 
> ```shell
> pwsh -ExecutionPolicy Bypass -File .\Build-ModLoader-Local.ps1
> ```
> ）。

模拟 GitHub Actions 里**手动触发并填写版本号**（对应 `workflow_dispatch` 的 `version` 输入）：

```shell
.\Build-ModLoader-Local.ps1 -Version 0.5.12.13
```

---

## 2. 环境要求

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| 操作系统 | Windows 10 / 11 | 工作流本身就跑在 `windows-latest` |
| PowerShell | 5.1+ 或 PowerShell 7+ | 脚本兼容两者 |
| Node.js | **18.x（推荐）**，最低 17.3 | 工作流使用 `node-version: 18.x`；脚本会检查并给出提示 |
| Git for Windows | 任意较新版本 | 用于子模块与外部仓库检出 |
| corepack | Node.js 16.9+ 自带 | 自动下载并调用 `yarn@3.4.1`，**无需 `corepack enable`（无需管理员权限）** |
| 磁盘空间 | ≥ 10 GB | 实测 27 个 `node_modules` 合计约 3.3 GB，加上源码、`SC2`、`output` 与中间产物，建议预留 10 GB |

### 构建结束后 `git status` 的变化

构建只会额外产生一个未跟踪文件：`ModLoader\out\README.md`。它是工作流里
`Copy README.md` 步骤的产物（`-Clean` 会删除、构建时会重建），不是源码改动。
`ModLoader` 子模块自带的 `.gitignore` 已覆盖 `dist*`、`node_modules`、`mod` 等全部构建产物。
| 网络 | 首次构建需要 | 拉取子模块 / SC2 / GameOriginalImagePack，以及 yarn、npm 依赖 |

Node.js 18 下载：<https://nodejs.org/download/release/latest-v18.x/>

本机已验证环境：Node.js `v24.19.0`、npm `12.0.2`、git `2.52.0`、corepack `0.35.0`。

---

## 3. 产物在哪

构建成功后：

| 产物 | 路径 | 对应 CI 中的 |
| --- | --- | --- |
| 完整发布包 | `output\DoL-ModLoader-<sha>.zip` | `Archive Release (Artifact)` |
| 手动版本号命名 | `output\DoL-ModLoader-<version>-<sha>.zip` | `Rename Archive (Manually)` |
| 原版图片 mod | `out-GameOriginalImagePack\GameOriginalImagePack.mod.zip` | `Upload GameOriginalImagePack.mod.zip` |
| 已就绪的发布资产 | `release\` | `Archive Release (Releases Manually)` |
| 可直接游玩的 HTML | `DoL\Degrees of Lewdity VERSION.html.sc2patch.html.mod.html` | `Copy html` 的源文件 |
| 兼容版 HTML | `DoL\Degrees of Lewdity VERSION.html.sc2patch.html.mod-polyfill.html` | `Copy html-compatibility` 的源文件 |
| 构建日志 | `build-logs\Build-ModLoader-Local.latest.log` | （CI 控制台日志） |

`output\DoL-ModLoader-<sha>.zip` 内部结构：

```
Degrees of Lewdity VERSION.html.sc2patch.html.mod.html           ← 普通版
Degrees of Lewdity VERSION.html.sc2patch.html.mod-polyfill.html  ← 兼容版
img\...                                                          ← 游戏图片
```

拿 `release\` 里的两个文件就可以直接在 GitHub 上创建 Release
（`DoL-ModLoader-<version>-<sha>.zip` + `GameOriginalImagePack.mod.zip`）。

---

## 4. 参数说明

| 参数 | 作用 |
| --- | --- |
| `-Version <字符串>` | 等价于 `workflow_dispatch` 的 `version` 输入：额外生成 `DoL-ModLoader-<version>-<sha>.zip` 并复制到 `release\`。**不传时会交互式询问**，直接回车即跳过 |
| `-Sha <字符串>` | 覆盖产物文件名中的 commit sha（默认取 `git rev-parse --short=8 HEAD`） |
| `-SkipInit` | 跳过 `git submodule update` / clone SC2 / clone GameOriginalImagePack（离线或重复构建用） |
| `-PinnedSubmodules` | 子模块**不**拉取最新版本，改用父仓库记录的那个 commit（复现历史构建用）。默认是更新到各子模块跟踪分支的最新 commit |
| `-SkipYarnInstall` | 跳过所有 `yarn install`（`node_modules` 已就绪时大幅加速，**重复构建推荐**） |
| `-SkipSc2` | 跳过 SC2 的 `npm install` + `build.js -d -u -b 2`（该产物不参与最终 HTML，见下方说明） |
| `-SkipGameOriginalImagePack` | 跳过 GameOriginalImagePack 的下载与打包 |
| `-OnlyPackage` | 只重做「注入 + 打包」阶段，复用已有的中间产物（改 `modList.json` 后快速重新出包） |
| `-Clean` | 构建前清理生成物：`ModLoader\out` 下的 `dist-*`/`mod`/`README.md`、`output`、`out-GameOriginalImagePack` 与 DoL 的 HTML 产物。**只删生成物**，`ModLoader\out` 里受版本控制的 `modList.json`、`ManualPolyfill.js`、`insert*.bat` 会被保留 |

典型组合：

```shell
# 第一次完整构建
.\Build-ModLoader-Local.ps1 -Version 0.5.12.13

# 第二次构建（只改了 mod 源码，跳过拉取与依赖安装）
.\Build-ModLoader-Local.ps1 -Version 0.5.12.13 -SkipInit -SkipYarnInstall

# 只改了 modList.json，想快速重新出包
.\Build-ModLoader-Local.ps1 -SkipInit -SkipYarnInstall -OnlyPackage
```

---

## 5. 步骤对照表

脚本会按顺序打印与下表一致的阶段，方便和 YAML 逐条核对。

| # | 本地脚本 | 工作流 YAML |
| --- | --- | --- |
| 1 | `git submodule sync --recursive` + `git submodule update --init --recursive --remote`（仓库根 + `ModLoader`），并打印版本变化明细 | `actions/checkout@v6` (`submodules: true`) + `Update all submodules to latest remote` + `init ModLoader` |
| 2 | `git clone/fetch SC2`（`Lyoko-Jeremie/sugarcube-2_Vrelnir@TS2`） | `SugarCube-2` (`actions/checkout`) |
| 3 | `corepack yarn install` + `ts:BeforeSC2` / `webpack:BeforeSC2` / `webpack:BeforeSC2-comp` / `ts:ForSC2` / `webpack:insertTools` / `tras:babel` | `corepack enable` + `Build ModLoader` |
| 4 | 逐个 mod：`yarn install` → `build:ts` / `build:webpack`（`TweeReplacerLinker` 另有 `ts:type`，`ImageLoaderHook` 另有 `build-core:webpack`）→ `node dist-insertTools\packModZip.js <boot.json>` | 各 `Build <Mod>` 步骤 |
| 5 | 复制 `*.mod.zip` → `ModLoader\out\mod\<Mod>\` | 各 `Copy <Mod>` (`js-copy-github-action`) |
| 6 | `git clone GameOriginalImagePack` → `yarn install` + `build:ts/build:webpack/build:tools` → 复制 `DoL\img` → `readGameVersion.js` → `bootJsonFillTool.js` → `packModZip.js` | `Checkout/Build/Make GameOriginalImagePack` + `ReadGameVersion` |
| 7 | 复制 `dist-BeforeSC2`、`dist-BeforeSC2-comp`、`dist-BeforeSC2-comp-babel`、`dist-ForSC2`、`dist-insertTools`、`README.md` → `out\` | 对应 6 个 `Copy ...` 步骤 |
| 8 | `npm install` + `node build.js -d -u -b 2`（在 `SC2\`） | `Build SC2` |
| 9 | `DoL\compile.bat`（tweego 编译游戏） | `Build DoL (Win)` |
| 10 | `node dist-insertTools\sc2PatchTool.js` | `Patch SC2 In DoL Html` |
| 11 | `node dist-insertTools\insert2html.js` | `Inject ModLoader` |
| 12 | `node dist-insertTools\insert2html-polyfill.js` | `Inject ModLoader-compatibility` |
| 13 | 复制 2 个 HTML + `DoL\img` → `output\`，用 `System.IO.Compression` 打包 | `Copy html` / `Copy img (Win)` / `zip-release` |
| 14 | 版本号重命名 + 复制到 `release\` | `Rename Archive (Manually)` + `action-gh-release` |

---

## 5.1 子模块版本策略（重要）

**问题**：`actions/checkout` 与 `git submodule update --init --recursive` 只会把子模块
检出到**父仓库记录的那个 commit**（gitlink）。ModLoader 记录的这些 commit 可能已经
落后于各子模块仓库的最新版本，例如本项目当前状态：

| 子模块 | 父仓库记录的 commit | 远端 master 最新 |
| --- | --- | --- |
| `mod/ModLoaderGui` | `8494b7b6` | `41db3900` |
| `mod/ModdedClothesAddon` | `09d116fc` | `a85701fd` |

**现在的做法**：构建前给每个子模块执行 `fetch` 并检出其跟踪分支的最新 commit：

```shell
git submodule sync --recursive
git submodule update --init --recursive --remote
```

- `--remote` 让 git 使用每个子模块在 `.gitmodules` 中声明的 `branch`；
  ModLoader 的 28 个子模块里有 24 个显式写了 `branch = master`。
  剩下 4 个没写 `branch`（`mod/i18n`、`mod/ModSubUiAngularJs`、`mod/CheckGameVersionCot`、
  `mod/ImageLoaderHook2BeautySelectorAddon`）会回退到远端 `HEAD`，而这四个仓库的
  `origin/HEAD` 都指向 `master`，所以结果一致。
- `ModLoader` 自身被主仓库记录的 commit 是 `933b235`，恰好就是它 `origin/master` 的
  最新 commit，所以不需要再额外更新它。
- `--recursive` 只更新**内层**子模块的 commit，**不会**改变 `ModLoader` 自身被主仓库
  记录的 commit（那取决于 `actions/checkout`）。
- 每次构建都会在日志里打印版本变化明细，例如：

  ```
  OK   共 2 个子模块被更新到新版本:
    * mod/ModdedClothesAddon  09d116fc -> a85701fd
    * mod/ModLoaderGui  8494b7b6 -> 41db3900
  ```

**想复现历史版本**（使用父仓库记录的 commit）：本地加 `-PinnedSubmodules`；
CI 里把新增的 `Update all submodules to latest remote` 步骤删掉或注释即可。

> **注意**：`--remote` 也会把 `DOL`（游戏本体）更新到 gitgud.io 上 `master` 的最新
> commit。如果你希望游戏本体固定、只更新 mod，请把根目录那次 `submodule update`
> 的限制去掉 `--remote`，只保留 `ModLoader` 目录里的那次。

---

## 5.2 与 CI 的有意差异

1. **不用 `corepack enable`**：它需要管理员权限写入 Node 安装目录。脚本改用
   `corepack yarn <命令>` 直接调用 `package.json` 中声明的 `yarn@3.4.1`，效果等价。
2. **不自动创建 GitHub Release**：本地没有 `GITHUB_TOKEN` 语义，脚本改为把资产放进
   `release\` 目录，由你手动上传（或自行执行 `gh release create`）。
3. **`SC2` 构建可选**：工作流里 `Build SC2` 产出的
   `SC2\build\twine2\sugarcube-2\format.js` 不参与最终 HTML（DoL 用的是它自带的
   `devTools\tweego\storyFormats\sugarcube-2\format.js`），YAML 中复制它的步骤本身也是注释掉的。
   脚本默认仍然执行以保持一致性，可用 `-SkipSc2` 跳过。
4. **步骤失败即中止**：等价于 GitHub Actions 的默认 `fail-fast` 行为，日志会明确标出失败命令。

---

## 6. 常见问题

**Q: 报 `yarn install` 相关错误 / lockfile 冲突？**
脚本已设置 `YARN_ENABLE_IMMUTABLE_INSTALLS=false`，避免 lockfile 轻微漂移导致失败。
若仍失败，删除对应目录的 `node_modules` 后重试。

**Q: Node.js 版本相关报错（webpack / babel / OpenSSL）？**
工作流固定使用 Node 18.x。虽然 Node 20/22/24 通常也能通过，但如遇
`error:0308010C:digital envelope routines::unsupported` 之类的报错，
请安装 <https://nodejs.org/download/release/latest-v18.x/> 的 Node 18 后重新运行。
脚本启动时会打印本机 Node 版本并给出提示。

**Q: 我的 `DOL` / `DoL` 目录名大小写不一致，会有问题吗？**
不会。Windows 文件系统不区分大小写，工作流本身也是混用
`${{ github.workspace }}/DOL` 与 `${{ github.workspace }}/DoL` 的。

**Q: `git submodule update` 拉取 `gitgud.io` 很慢或失败？**
DoL 仓库在 `gitgud.io` 上，国内网络可能不稳定。可以：
1. 使用已存在的 `DOL` 目录并加 `-SkipInit`；
2. 或先手动执行 `git submodule update --init --remote --recursive`（见仓库根
   [readme.md](readme.md)）重试几次。

**Q: 构建中断后想续跑？**
脚本不缓存中间状态，请直接重跑；建议加上
`-SkipInit -SkipYarnInstall`。若只是最后打包阶段失败，用 `-OnlyPackage`。

**Q: `release\` 里怎么只有本次构建的文件？**
每次构建只清理**本次要生成**的那几个同名资产（`DoL-ModLoader-<sha>.zip`、
`DoL-ModLoader-<version>-<sha>.zip`、`GameOriginalImagePack.mod.zip`）后重新生成，
避免旧版本被误上传；**其它文件（例如你手工放进去的说明文件或额外 mod）不会被删除**。

**Q: 子模块更新到最新后，仓库里 `ModLoader` 显示为已修改？**
正常现象。`git submodule update --remote` 会把子模块工作区切到最新 commit，
于是父仓库里那个 gitlink 与工作区不一致，`git status` 会显示 `m ModLoader`。
这只影响工作区，不会改动你已提交的内容；想恢复父仓库记录的版本执行
`git submodule update --init --recursive`（或构建时加 `-PinnedSubmodules`）即可。

**Q: 产物 zip 里两个 HTML 有什么区别？**
`*.mod.html` 是普通版；`*.mod-polyfill.html` 额外内嵌了
`polyfillWebpack.js` 与 `ManualPolyfill.js`，用于老浏览器兼容（对应 CI 的
`Inject ModLoader-compatibility`）。两者都会打进发布包。

**Q: 提示 `产物冒烟校验 ... 体积异常偏小`？**
说明 DoL 编译产物或注入结果不正常（常见原因是 `compile.bat` 失败或 tweego 被杀软拦截）。
请查看 `build-logs\` 中的日志定位。

---

## 7. 冒烟校验

脚本内建了三道校验，避免「构建成功但产物是空壳」：

1. `ModLoader\dist-*`、`dist-insertTools\*.js` 等中间产物必须存在；
2. 两个最终 HTML 中必须能搜到 `window.modDataValueZipList`、`modSC2DataManager`、
   `window.mainStart`（游戏本体入口未被破坏）、`id="polyfillManual"`，且体积 > 1 MB；
3. 打包完成后打印产物路径、大小、zip 条目数与 SHA256。

---

## 8. 相关文件

| 文件 | 说明 |
| --- | --- |
| `Build-ModLoader-Local.ps1` | 主构建脚本 |
| `Build-ModLoader-Local.bat` | 一键启动器（双击即可） |
| `LocalBuild-README.md` | 本说明文档 |
| `readGameVersion.js` | 读取游戏版本号（CI 与本地共用） |
| `.github/workflows/Build-Html-Package.yml` | 被复刻的原始工作流 |
