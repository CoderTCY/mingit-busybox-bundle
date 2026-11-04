# MinGit BusyBox Bundle

非官方 Windows 10/11 原生 x64 离线整合安装器：重编的 MinGit (BusyBox)、Git LFS、同源 Git HTML 手册和全部 native Git gettext catalogs。自有整合代码采用 GPL-2.0-only；第三方代码保留原作者与许可。

## 构建输入

`build/toolchain.lock.json` 固定构建配方与工具版本。`scripts/resolve-inputs.ps1` 将稳定版本、解引用源码 commit、官方资产 SHA-256、本地补丁及本工程 commit 写成一次性输入快照；已有快照拒绝覆盖。GitHub API 错误会失败，不代表“没有更新”。

```powershell
pwsh -NoProfile -File scripts/resolve-inputs.ps1 -GitTag v2.56.0.windows.4 -LfsTag v3.8.1 -OutputPath build/inputs.json
pwsh -NoProfile -File scripts/build.ps1 -InputsPath build/inputs.json -SdkRoot C:\git-sdk-64 -OutputRoot build
```

SDK 必须是官方 `setup-git-for-windows-sdk` 锁定提交的 `build-installers` flavor，使用 `MSYSTEM=UCRT64`、`MINGW_PREFIX=/ucrt64`。编译目录不得含空格；最终安装目录支持空格与中文。所有产物在被忽略的 `build/work/`、`build/payload/`、`build/test-results/` 和 `dist/`，不得提交二进制、缓存或凭据。

`patches/0001-core-shell.patch` 移植 Johannes Schindelin 的 [PR #3301](https://github.com/git-for-windows/git/pull/3301) 两个固定提交的生产改动，未引入其 mock-shell 测试。`patches/0002-package-inputs.patch` 适配固定的官方 split-package 配方；保留 gettext、Rust、TLS 和内部需要的 man 目标。构建版本带 `.busyboxbundle.<recipe>`，不是官方未修改二进制。

固定 Action 不能冻结整个滚动 SDK；构建记录实际 pacman 包和 compiler 版本，不承诺字节级可复现。产品没有可信代码签名证书，安装器为未签名自定义构建，不是 Git for Windows 官方签名发行版。
