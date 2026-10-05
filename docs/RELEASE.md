# 发布流程

产物**不进版本库**，全部作为 **GitHub Release 的资产**上传。仓库里只有源码、
构建脚本和文档。

---

## 一、自动化发布（推荐）

打一个 tag，剩下的交给 GitHub Actions：

```bash
# 1) 确保要发布的内容已经在 main 上
git checkout main
git pull
git log --oneline -1

# 2) 打 tag 并推送（触发 Release 工作流）
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

`.github/workflows/release.yml` 会自动：

1. **构建全矩阵**（6 个 Linux 目标 + 1 个 Windows）
2. **逐个验收**：`verify-release.py` 检查架构是否与文件名一致、组件是否齐全
3. **上传为 Release 资产**，并附一份 `SHA256SUMS.txt`

跑到 `Actions` 页面就能看进度。ARM 目标走 QEMU 模拟，单个约 20–60 分钟，
整个流程通常 **40–90 分钟**。

### 先测再发

不想直接发版就先手动跑一遍（只构建、不发布），在
`Actions → Release → Run workflow` 填个版本号即可；或者在本地：

```bash
./build-docker.sh --list      # 看构建计划
./build-docker.sh             # 本地构建（需要 Docker）
python3 verify-release.py dist/
```

确认没问题再打 tag。

---

## 二、手动发布

```bash
# 1) 本地构建（需要 Docker；ARM 走 QEMU 较慢）
./build-docker.sh

# 2) 验收
python3 verify-release.py dist/
# 期望输出：每个文件「架构与文件名一致」+ 组件齐全 + 依赖库命中，末尾「通过」

# 3) 把 dist/ 里的文件拖到 GitHub Release 页面
#    Releases → Draft a new release → 选 tag → 上传附件

# 4) Windows 产物
#    在 Windows 上跑： build-windows.cmd -SingleFile -Clean
#    产物 dist\scrcpy-gui-zh.exe，重命名为 scrcpy-gui-zh-<版本>-windows-x86_64.exe
```

---

## 三、资产命名规范

```
scrcpy-gui-zh-1.0.0-linux-glibc2.31-x86_64         ← debian:11 构建，兼容面最广
scrcpy-gui-zh-1.0.0-linux-glibc2.35-x86_64         ← ubuntu:22.04 构建
scrcpy-gui-zh-1.0.0-linux-glibc2.39-x86_64         ← ubuntu:24.04 构建
scrcpy-gui-zh-1.0.0-linux-glibc2.31-aarch64        ← arm64（树莓派 4/5 64 位系统）
scrcpy-gui-zh-1.0.0-linux-glibc2.31-armv7l         ← 32 位 ARM
scrcpy-gui-zh-1.0.0-windows-x86_64.exe             ← Windows
```

**为什么不叫 `debian` 版本**：glibc 只能向后兼容，Ubuntu 22.04（2.35）构建的产物
在 Debian 11（2.31）上会报 `GLIBC_2.35 not found`。名字里写 **glibc 版本**，
用户一眼就知道能不能用，也不会误以为"Debian 全系都能装"。

---

## 四、发布前检查清单

- [ ] `python3 verify-release.py dist/` 全部「通过」
- [ ] 架构覆盖齐全：x86_64 / aarch64 / armv7l / windows-x86_64
- [ ] 每个产物都带 glibc 下限（文件名里能看出来）
- [ ] `CHANGELOG.md` 已更新，`git log` 里没有未提交的改动
- [ ] Release 说明里写明：
  - [ ] Linux 上首次使用要装一次 udev 规则（程序会引导）
  - [ ] **ARM 产物不支持无线配对**（`adb pair` 需要 platform-tools ≥ 30，
        Google 官方只提供 x86_64 版）—— USB 与「USB 转无线」正常
  - [ ] 无桌面环境的服务器上跑不起来（需要 X11/Wayland）

---

## 五、为什么二进制不进版本库

单个产物 24–250 MB，全套多架构 300–600 MB；每发一版都会**永久留在 git 历史里**，
克隆越来越慢。GitHub Release 资产是专门放这个的：可单独下载、可统计下载量、
不拖累仓库。`.gitignore` 里已经忽略 `release/` 和 `dist/`。
