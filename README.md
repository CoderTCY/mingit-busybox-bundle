# MinGit BusyBox Bundle

非官方 Windows 10 1903+ / Windows 11 原生 x64 离线整合安装器：重编的 MinGit (BusyBox) 与 Git LFS、同源 Git HTML 手册和全部 native Git gettext catalogs。自有构建与整合代码采用 GPL-2.0-only；第三方代码及 LFS 组件补丁保留上游许可（LFS 为 MIT）与作者归属。

## 构建输入

`build/toolchain.lock.json` 固定构建配方与工具版本。`scripts/resolve-inputs.ps1` 将稳定版本、解引用源码 commit、官方资产 SHA-256、本地补丁及本工程 commit 写成一次性输入快照；已有快照拒绝覆盖。GitHub API 错误会失败，不代表“没有更新”。

PE 数值版本使用 Git 的四段版本；含 LFS 和 recipe 的完整版本写入文本版本资源。官方 `.windows.1` 的 ZIP 文件名省略末尾 `.1`，输入解析只在资产名中处理该规则，不改变锁定 tag、commit 或四段版本。

日常构建、打包和安装验收在 GitHub Actions 的独立 Windows runner 上执行，不要求在开发机编译：

```powershell
gh workflow run release.yml --repo CoderTCY/mingit-busybox-bundle -f git_tag=v2.56.0.windows.4 -f lfs_tag=v3.8.1
```

工作流调用同一组 `scripts/resolve-inputs.ps1`、`scripts/build.ps1` 和 `tests/invoke-verify.ps1` 入口。同一次 GitHub run 重跑复用原始输入 artifact；同一已发布身份成功跳过，不覆盖公开资产。

独立的 `keepalive.yml` 每周日 02:41 UTC（北京时间 10:41）检查默认分支最新提交的 committer 时间；未满 52 天不做改动，达到阈值时由 `github-actions[bot]` 创建一个不改文件内容的空提交，再正常推送到默认分支。仅允许默认分支执行，不强推；手动运行也遵守同一阈值。

保活空提交会改变 `recipeCommit`，因此后续每日发布检查会将其视为新的构建身份，仍须通过完整构建和验收。此机制用于降低公开仓库因 60 天无活动而停用定时 workflow 的风险，不保证 GitHub 调度准时；已经停用的 workflow 仍需手动重新启用。

失败续跑应选择保留原 artifact 的失败 job 重跑。GitHub 的 `Re-run all jobs` 会删除上一轮 artifacts；原输入快照缺失或过期时，本项目明确失败而不是重新读取 latest，须开启新的手动运行。

SDK 使用官方 `setup-git-for-windows-sdk` 锁定提交的 `full` flavor，使用 `MSYSTEM=UCRT64`、`MINGW_PREFIX=/ucrt64`。编译目录不得含空格；最终安装目录支持空格与中文。所有产物在被忽略的 `build/work/`、`build/payload/`、`build/test-results/` 和 `dist/`，不得提交二进制、缓存或凭据。

`patches/0001-core-shell.patch` 移植 Johannes Schindelin 的 [PR #3301](https://github.com/git-for-windows/git/pull/3301) 两个固定提交的生产改动，未引入其 mock-shell 测试。`patches/0002-package-inputs.patch` 适配固定的官方 split-package 配方；保留 gettext、Rust、TLS 和内部需要的 man 目标。构建版本带 `.busyboxbundle.<recipe>`，不是官方未修改二进制。

Windows 的 `sh`、`bash` shebang 都使用已配置的 `core.shell`，不会因系统 PATH 中存在 `bash.exe` 而误启动 WSL。本包提供 BusyBox ash 支持的 shell 语法，不包含完整 GNU Bash。

原生 BusyBox 不进行 MSYS 的参数路径转换；第一份补丁也在 Git 的 `file://` 解析边界把标准 Windows URI 的 `/C:/...` 转为原生 `C:/...`，保留其他协议、UNC 和 POSIX 路径的原有处理。

BusyBox 同样从锁定的 `d8d8bb397f1e200ba5a871dc6aa4af819b23f32a` 重编：`0003-busybox-unicode.patch` 复用宽字符路径查询所有权，并启用[上游 UTF-8 manifest 模式](https://frippery.org/busybox/release-notes/FRP-5181.html)。安装器最低版本为 Windows 10 build 18362，BusyBox 自身也拒绝不支持该 manifest 的系统；保留原配方的 TLS、权限检查及其他功能，而非整体换用功能集不同的 defconfig。

ash 默认启用已有的 `winxp` 选项，仅为保留继承环境变量的反斜线与转义，不表示支持 Windows XP；需要旧式自动路径转换时仍可显式使用 `+X`。这样不会把 `GIT_CONFIG_PARAMETERS` 的转义改成 `/`。`0004-busybox-package-inputs.patch` 复用官方 BusyBox 配方，固定源码与补丁校验和，使用原生 `EXTRAVERSION` 标出 `.busyboxbundle.<recipe>`；Git 和 BusyBox 均附本次构建的完整 `--allsource` 归档。

稳定源码中的 `t0061` 有两处后台命令没有分组，会破坏测试自身的动态 `&&` 链检查。第一份补丁同时修正这两处测试语法，保留 poll-limit 的全部断言；不禁用链检查。源码回归入口为 `make test T=t0061-run-command.sh`，不能代替安装后的 BusyBox/LFS/locale/帮助验收。

CI 通过固定的官方 SDK Action 使用 `full` flavor；旧 `build-installers` 子集生成器不兼容 SDK 的 `docx2txt` → `docx2txt-rs` 换包，会在缺少签名工具的中间状态生成不完整 SDK。完整检出避免该路径，不禁用 pacman 签名校验。构建入口仍检查实际工具与 DLL，并从官方包补齐缺失依赖，不以 `NO_RUST` 或 `NO_GETTEXT` 绕过错误。离线手册使用 Asciidoctor 的 `webfonts!` 属性，不引用远程字体。

LFS 从官方 `git-lfs-vendor-<tag>.tar.gz`（含 vendored modules）重编，不使用目标版本的官方二进制代替。`0005-lfs-core-shell.patch` 让 Windows shell 调用通过 `git var GIT_SHELL_PATH` 取得 `core.shell`，涵盖 custom/file transfer 和需要 shell 的 SSH 路径；查询或配置的 shell 不可用时失败，不回退外部 `sh`。安装树仍只有原定 `ash.exe` 入口。

LFS 保留上游语义版本，通过原有 `config.Vendor=MinGitBusyBoxBundle.r<recipe>` 与完整 `config.GitCommit` 链接字段明确标识自定义构建。Go 1.27.3、Windows 资源生成器及其源码依赖均有固定 SHA-256；文档复用 SDK 的 Ruby/Asciidoctor。构建使用 vendor 模式，禁止隐式模块或工具链下载，保留 Windows 资源、内置帮助与翻译生成步骤。

LFS 构建在独立 PowerShell 子进程中运行，源码回归使用的临时 Git/Go 环境不会进入后续 payload 合成；不依靠易混淆的空字符串来恢复未设置的 `GIT_*` 变量。

来源附件包括原始 LFS vendor 归档、第五份补丁、构建记录、对应 Go runtime 源码和资源生成器源码；随包提供 Go 与 LFS/vendor notices。只有较旧 LFS 升级 fixture 使用经过校验的官方 ZIP，绝不作为主安装包的回退，也不会公开发布该 fixture。

固定 Action 不能冻结整个滚动 SDK；构建记录实际 pacman 包和 compiler 版本，不承诺字节级可复现。产品没有可信代码签名证书，安装器为未签名自定义构建，不是 Git for Windows 官方签名发行版。

## 安装、升级与卸载

正式 Release 的可安装产物只有一个 x64 EXE。Git、BusyBox、Git LFS、HTML 手册和 native gettext catalogs 全部内嵌且必装；安装期间不下载组件、不调用 LFS 或 Git 的其他安装器。其余 `inputs.json`、`build-manifest.json`、`sources.zip`、`SHA256SUMS` 为审计与对应源码附件。

公开 manifest 保留完整输入、组件来源和 payload 文件哈希。`components.lfsBuild.sourceTestShell` 是相对于 SDK 根目录、使用 `/` 分隔的路径，不记录构建机的绝对 SDK 位置。完整 SDK 包清单统一记录在顶层 `sdkPackages`；LFS 的 `documentationToolchain` 仅保留 Asciidoctor、Ruby、msgfmt 的版本命令输出，不重复嵌入包清单。源码附件中的 LFS 构建记录采用同一格式。

默认安装到当前用户；同一安装器支持 `/CURRENTUSER` 和 `/ALLUSERS`。升级沿用同范围的原目录；改变范围或目录须先卸载，不自动卸载、迁移现有 Git。唯一可选项仅追加本产品的 `cmd` 到对应范围 PATH；原来已有的等价项不会被认领，其他 token 原文与顺序保留。安装后重新打开终端并运行 `where git`，其他 Git 可能仍在前面。

卸载从本产品持久化记录确认范围和目录，不依赖当前提权状态；只清理对应范围的自有记录。

`etc/gitconfig.bundle` 是随版本更新的产品默认值。`etc/gitconfig` 只在首次缺失时创建，升级不覆盖、卸载不删除；仓库配置、用户 global config 和非产品文件不属于卸载范围。废弃产品文件仅按经过路径与 reparse-point 校验的旧清单差集删除。

```powershell
git help -w commit
git lfs version
git lfs install --local
```

LFS filters 已预设在产品 system config；最后一条仅在用户需要 LFS 的仓库中执行，用于建立该仓库的真实 pre-push hook。安装器不会写入用户 global config。本地化指 native Git gettext catalogs，不表示 HTML 手册全部为中文。

## 发布门禁

工作流每日检测当时的上游最新稳定版，也支持固定 tag 的手动运行。PR 只构建和验证。两个全新 Windows runner 分别验收真正受限账户的 CurrentUser 和管理员 AllUsers 安装、真实旧 LFS 升级、PATH 所有权、卸载保留，以及同一 payload 的 shell alias、本地传输、hooks、重定位、中文/C locale、实际默认浏览器离线帮助和真实 LFS `file:///` 上传/clone 自动 checkout。

卸载验收通过 `Start-Process -Wait` 等待 Inno 的整个两阶段进程树，再核对登记、PATH 和文件；仅等待注册的 `unins*.exe` 退出会早于第二阶段的 `usPostUninstall` 清理。外层验收仍有超时限制，不用固定延时或重试掩盖残留。

浏览器夹具仅允许在 disposable GitHub runner 上运行：暂存并还原 Edge 的 per-user HTML 启动命令，使用独立 profile 收集真实桌面与 DOM/CSS 证据，不重写扩展名默认值或伪造 `UserChoice`。产品安装器不修改 Windows 默认浏览器；打开手册仍通过 `ShellExecuteW` 使用系统选择。

LFS 离线 roundtrip 不代表已覆盖 HTTPS、代理、认证或服务器锁 API。源码缺失、UI 无法实际显示或任何行为门禁失败都会阻止正式发布；已编译 EXE 可留在失败工作流的 artifact 中用于诊断，但不能当作通过验收的 Release。每日调度不保证准时，也不保证捕捉已被后续版本替代的每个上游版本；本产品没有驻留客户端自动升级服务。

发布使用创建 API 返回的精确 Release ID 继续上传和核验，不依赖刚创建的草稿立即出现在分页列表中。只有原始输入一致的草稿可恢复；公开 Release 不覆盖。同一 run 重跑恢复原输入快照，相同输入的新运行跳过已发布产物。

对应源码按实际 payload 文件所属包及 pacman `%BASE%`/精确版本去重，保留官方 `.src.tar.gz` 或 `.src.tar.zst` 归档、来源 URL、SHA-256、配方、补丁和随包许可证。SDK 的合法空元包没有文件清单；安装后生成的 `etc/gitattributes` 另与该版本 `git-extra` 的生成脚本核对。未随 payload 分发且已被 SDK 裁剪的文档不作为安装文件要求，完整对应源码仍单独收集，缺失即阻断发布。
