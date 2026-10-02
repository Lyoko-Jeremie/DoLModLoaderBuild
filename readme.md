
# 附带"[ModLoader](https://github.com/Lyoko-Jeremie/sugarcube-2-ModLoader)"的"[Degrees of Lewdity](https://gitgud.io/Vrelnir/degrees-of-lewdity)"预构建发布项目

本仓库用于自动构建附带ModLoader的DoL游戏。您可以在Release页面下载构建好的版本。

如果您需要在Android上游玩，您可以使用任意文件浏览器解压并点击html文件，使用任何您喜欢的浏览器打开html文件。
如果出现图片无法显示的问题，请加载 `GameOriginalImagePack.mod.zip` ，这个 `GameOriginalImagePack` mod 包含原始游戏的所有原版图片，请始终使其在mod列表的最后加载。

---

### en

# Pre-built Release of "[Degrees of Lewdity](https://gitgud.io/Vrelnir/degrees-of-lewdity)" with "[ModLoader](https://github.com/Lyoko-Jeremie/sugarcube-2-ModLoader)"

This repository is for automatic building of the DoL game with ModLoader included. You can download the built version on the Release page.

If you wish to play on Android, you can use any file explorer to unzip and click the html file, and open the html file with any browser you prefer.
If you encounter issues with images not displaying, please load `GameOriginalImagePack.mod.zip`. This `GameOriginalImagePack` mod contains all the original images from the base game and should always be loaded last in the mod list.

---

### Update Submodules (ModLoader & DoL) / 更新模组管理器和游戏本体源码
```shell
git submodule update --init --remote --recursive
```

> 构建工作流与本地构建脚本现在**都会**在构建前执行上面的命令，把 `DOL`、`ModLoader`
> 以及 ModLoader 下的全部 mod 子模块更新到各自跟踪分支的**最新 commit**，
> 不再使用父仓库里记录的旧 commit。

---

### 本地构建 / Local Build (Windows)

不想用 GitHub Actions 时，可以在本地 Windows 电脑上跑同一套流程：

```shell
.\Build-ModLoader-Local.ps1
```

它会复刻 `.github/workflows/Build-Html-Package.yml` 的全部步骤（更新子模块 → 构建
ModLoader 与各 mod → 编译 DoL → 注入 → 打包），产物与 CI 一致：
`output\DoL-ModLoader-<version>-<sha>.zip` 与 `release\GameOriginalImagePack.mod.zip`。

详见 [`LocalBuild-README.md`](LocalBuild-README.md)。

