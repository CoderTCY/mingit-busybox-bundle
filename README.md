# MinGit BusyBox Bundle

非官方 Windows 10/11 原生 x64 离线整合安装器：重编的 MinGit (BusyBox)、Git LFS、同源 Git HTML 手册和全部 native Git gettext catalogs。自有整合代码采用 GPL-2.0-only；第三方代码保留原作者与许可。

## 构建输入

`build/toolchain.lock.json` 固定构建配方与工具版本。`scripts/resolve-inputs.ps1` 将稳定版本、解引用源码 commit、官方资产 SHA-256、本地补丁及本工程 commit 写成一次性输入快照；已有快照拒绝覆盖。GitHub API 错误会失败，不代表“没有更新”。

日常构建、打包和安装验收在 GitHub Actions 的独立 Windows runner 上执行，不要求在开发机编译：

```powershell
gh workflow run release.yml --repo CoderTCY/mingit-busybox-bundle -f git_tag=v2.56.0.windows.4 -f lfs_tag=v3.8.1
```

工作流调用同一组 `scripts/resolve-inputs.ps1`、`scripts/build.ps1` 和 `tests/invoke-verify.ps1` 入口。同一次 GitHub run 重跑复用原始输入 artifact；同一已发布身份成功跳过，不覆盖公开资产。

SDK 必须是官方 `setup-git-for-windows-sdk` 锁定提交的 `build-installers` flavor，使用 `MSYSTEM=UCRT64`、`MINGW_PREFIX=/ucrt64`。编译目录不得含空格；最终安装目录支持空格与中文。所有产物在被忽略的 `build/work/`、`build/payload/`、`build/test-results/` 和 `dist/`，不得提交二进制、缓存或凭据。

`patches/0001-core-shell.patch` 移植 Johannes Schindelin 的 [PR #3301](https://github.com/git-for-windows/git/pull/3301) 两个固定提交的生产改动，未引入其 mock-shell 测试。`patches/0002-package-inputs.patch` 适配固定的官方 split-package 配方；保留 gettext、Rust、TLS 和内部需要的 man 目标。构建版本带 `.busyboxbundle.<recipe>`，不是官方未修改二进制。

稳定源码中的 `t0061` 有两处后台命令没有分组，会破坏测试自身的动态 `&&` 链检查。第一份补丁同时修正这两处测试语法，保留 poll-limit 的全部断言；不禁用链检查。源码回归入口为 `make test T=t0061-run-command.sh`，不能代替安装后的 BusyBox/LFS/locale/帮助验收。

SDK 子集可能保留 pacman 登记而裁掉实际工具或 DLL。构建入口从官方包恢复 MSYS Git、pacman、HTTPS 依赖、完整 GCC/CRT 及 Cargo 所需 SQLite，再执行官方配方；不以 `NO_RUST` 或 `NO_GETTEXT` 绕过缺依赖。离线手册使用 Asciidoctor 的 `webfonts!` 属性，不引用远程字体。

LFS 对应源码取官方 `git-lfs-vendor-<tag>.tar.gz`（包含 vendored modules），不是不含依赖的普通源码 tarball；安装包内的 LFS 许可证和第三方 notices 也来自这份已校验归档。

固定 Action 不能冻结整个滚动 SDK；构建记录实际 pacman 包和 compiler 版本，不承诺字节级可复现。产品没有可信代码签名证书，安装器为未签名自定义构建，不是 Git for Windows 官方签名发行版。

## 安装、升级与卸载

正式 Release 的可安装产物只有一个 x64 EXE。Git、BusyBox、Git LFS、HTML 手册和 native gettext catalogs 全部内嵌且必装；安装期间不下载组件、不调用 LFS 或 Git 的其他安装器。其余 `inputs.json`、`build-manifest.json`、`sources.zip`、`SHA256SUMS` 为审计与对应源码附件。

默认安装到当前用户；同一安装器支持 `/CURRENTUSER` 和 `/ALLUSERS`。升级沿用同范围的原目录；改变范围或目录须先卸载，不自动卸载、迁移现有 Git。唯一可选项仅追加本产品的 `cmd` 到对应范围 PATH；原来已有的等价项不会被认领，其他 token 原文与顺序保留。安装后重新打开终端并运行 `where git`，其他 Git 可能仍在前面。

`etc/gitconfig.bundle` 是随版本更新的产品默认值。`etc/gitconfig` 只在首次缺失时创建，升级不覆盖、卸载不删除；仓库配置、用户 global config 和非产品文件不属于卸载范围。废弃产品文件仅按经过路径与 reparse-point 校验的旧清单差集删除。

```powershell
git help -w commit
git lfs version
git lfs install --local
```

LFS filters 已预设在产品 system config；最后一条仅在用户需要 LFS 的仓库中执行，用于建立该仓库的真实 pre-push hook。安装器不会写入用户 global config。本地化指 native Git gettext catalogs，不表示 HTML 手册全部为中文。

## 发布门禁

工作流每日检测当时的上游最新稳定版，也支持固定 tag 的手动运行。PR 只构建和验证。两个全新 Windows runner 分别验收真正受限账户的 CurrentUser 和管理员 AllUsers 安装、真实旧 LFS 升级、PATH 所有权、卸载保留，以及同一 payload 的 shell alias、本地传输、hooks、重定位、中文/C locale、实际默认浏览器离线帮助和真实 LFS `file:///` 上传/clone 自动 checkout。

LFS 离线 roundtrip 不代表已覆盖 HTTPS、代理、认证或服务器锁 API。源码缺失、UI 无法实际显示或任何行为门禁失败都会阻止正式发布；已编译 EXE 可留在失败工作流的 artifact 中用于诊断，但不能当作通过验收的 Release。每日调度不保证准时，也不保证捕捉已被后续版本替代的每个上游版本；本产品没有驻留客户端自动升级服务。
