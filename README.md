# ABUELA —— Windows 版移植到 Android

## 一、引擎鉴定结果

| 项目 | 结论 |
|---|---|
| 引擎 | **Godot Engine v4.7.2.stable.official**（官方 x86_64 Windows 导出模板） |
| 渲染后端 | `gl_compatibility`（OpenGL ES 3.0 / Compatibility 渲染器） |
| 脚本 | GDScript，导出时已编译为字节码（`.gdc`，GDSC + zstd 压缩） |
| 场景 | 二进制资源（`.scn` / `.res`），贴图是导入后的 `.ctex` |
| 打包方式 | exe 尾部内嵌 PCK（Godot PCK v4 格式，`PACK_REL_FILEBASE`） |
| 游戏本体 | ABUELA 3.0.9（Granny 风格恐怖游戏，西班牙语），主场景 `res://SCENES/UI/menu.tscn` |
| 资源规模 | 459 个文件 / 59.7 MB（含 2 段 OGV 结局动画） |

exe 里 PCK 的头部结构（`0x683120` 处）：`GDPC | ver=4 | 4.7.2 | flags=2 | file_base=112 | dir_offset | 目录表`，
目录表每项为 `u32 路径长度(4字节对齐) | 路径 | u64 offset | u64 size | md5(16) | u32 flags`。

**没有源码**：导出的 PCK 里只有编译后的 `.gdc`、二进制场景和已导入的 `.ctex`，原始 `.gd/.tscn/.png` 都不存在，
因此无法用编辑器重新导出——本次移植走的是「引擎 + 原始资源包」路线。

## 二、移植做法

### 1. 资源侧
用 Python 重写了一个 PCK 读写器（`tools/pck.py`），逐字节解出原 PCK，再把改动后的内容重新打成 PCK。

同时逆向了 Godot 的二进制项目设置 `project.binary`（ECFG 格式：
`"ECFG" | u32 条目数 | [u32 key长度 | key | u32 value长度 | value]`，value 为 4 字节对齐的变体编码），
从而可以安全地追加/修改项目设置（`tools/ecfg_patch.py`）。

### 2. 触屏层（核心）
原游戏是纯键鼠：
`move_*`=WASD、`camera_left/right`=玩家本体 yaw、`camera_up/down`=CameraPivot 俯仰、
`use`=鼠标左键（开火）、`interact`=E/右键、`run`=Shift、`crouch`=Ctrl、`jump`=Space、
`slot_1..4`=1~4、`drop_item`=Q。

新增 `touch/touch_controls.gd`，以 autoload 注入（`autoload/TouchControls`）：
- 左半屏虚拟摇杆（屏幕 42% 左侧任意位置按下才出现，**闲置时完全不可见，不遮挡画面**）→ 驱动 `move_*` 动作，推到底自动冲刺 `run`；
  输入经指数平滑（`JOY_SMOOTH`），帧率无关，移动更顺、不抖
- **多点触控按手指 index 归属**：左手摇杆 + 右手视角可同时进行，任一根手指抬起只释放它自己，
  不会像之前那样把摇杆一起断开
- 右半屏拖动 → 改写玩家 yaw 与 CameraPivot 俯仰（俯仰限幅 ±1.35 rad，与原游戏一致）；
  视角速度按分辨率放宽屏补偿，不同手机上同一段滑动转过的角度一致
- 右侧按钮（2 列 × 3 行，右下角）：`FIRE / USE / RUN / CROUCH / JUMP / DROP`，FIRE 在最易触到的右下角
- **物品栏直接点游戏自己的格子**：运行时找到玩家 `UI/InventoryUI/Slot1..4` 的控件矩形，
  点哪格就触发 `slot_1..slot_4`（不用额外的 1/2/3/4 按钮），也不会被误判成摇杆/视角
- 菜单界面：真机触摸由 Godot 原生按钮处理；仅桌面测试用的「模拟触摸」才转成鼠标点击
- 关闭了 `emulate_mouse_from_touch`，避免触摸被误判为开火；同时放行游戏自身 HUD 按钮
- **滑条与难度列表**：Godot 的 `Range`/`ItemList` 只接受鼠标事件，触屏下完全无响应，
  因此由触屏层接管——点/拖滑条按位置换算数值，点列表按行高换算索引（音乐音量、灵敏度、难度都因此可用）
- **强制全屏**：启动即设为 `WINDOW_MODE_FULLSCREEN`，并每帧检查复位；设置界面的
  Fullscreen 勾选框被置为勾选且禁用，无法退回窗口

### 3. Android 打包
Godot 4.7 的 Android 导出用的是**稀疏 PCK**（每个资源单独放进 `assets/`，外加一份 `assets/assets.sparsepck`
元数据，引擎按 `res://xxx` → `assets/xxx` 读取）。因此按官方 exporter 的格式还原：

```
assets/<资源路径>            460 个文件
assets/assets.sparsepck      pack header(flags=REL_FILEBASE|SPARSE_BUNDLE) + 目录表
```

再基于官方 `android_release.apk` 导出模板：
- **全部图标换成游戏角色**：各密度 `mipmap-*`（含 adaptive icon 的前景/背景/单色层）、
  无密度 `mipmap/`、以及启动画面 `drawable/splash_icon` 与 `splash_branding_image`，
  共 26 项，均取自游戏自带的 512×512 头像，不再残留 Godot 机器人
- `resources.arsc` 内等长替换应用名为 `ABUELA v3.0.9 Port`
- 保留模板原生库与 dex，签名用本机 SDK 的 `apksigner`（v2 + v3 签名）

> 说明：本机 SDK 的 build-tools 是 x86_64 版，在这台 arm64 机器上无法执行，qemu 也缺 amd64 库，
> 所以没用 `aapt2`/`zipalign`；改为直接操作模板 APK（图标同名替换 + ARSC 等长改字符串），
> 签名仍由本机 JDK + SDK 的 `apksigner` 完成。

## 三、仓库结构与构建

```
touch/touch_controls.gd   触屏控制层（运行时注入的 autoload，纯 GDScript）
touch/selftest.gd         自动化触屏测试（只打进测试包）
tools/pck.py              Godot PCK v4 读写器
tools/ecfg_patch.py       project.binary (ECFG) 解析/改写
tools/extract_base.py     从原始 exe 中提取未修改的资源基线包
tools/build_game.py       生成打补丁的资源包
tools/build_apk.py        基于官方模板生成并签名 APK
tools/fetch_template.py   按需从 1.2GB 模板包中只取 Android 模板（HTTP Range）
tools/setup.sh            本地一键准备依赖
assets/game_base.pck      原始资源包（Git LFS，58 MB）
.github/workflows/main.yml CI：构建 + 校验 + 产物
```

### 本地构建

```bash
bash tools/setup.sh                 # Pillow + 模板 + 检查 apksigner
python3 tools/build_game.py         # -> out/game_touch.pck
python3 tools/build_apk.py          # -> out/ABUELA.apk
```

首次克隆后需要拉取 LFS 资源：`git lfs pull`。
若没有 LFS，可用自己的游戏文件重新生成基线包：

```bash
ABUELA_EXE=/path/to/ABUELA.exe python3 tools/extract_base.py
```

可覆盖的环境变量：`ABUELA_BASE`（基线包或原始 exe）、`ABUELA_APKSIGNER`、
`ABUELA_KEYSTORE` / `ABUELA_KEYSTORE_PASS` / `ABUELA_KEYSTORE_ALIAS`、`ANDROID_HOME`。

### CI

推送到 `main` 或开 PR 时会构建 APK 并上传为 artifact；打 `v*` 标签会自动创建 Release 并附上 APK。

## 四、产物

| 文件 | 说明 |
|---|---|
| `out/ABUELA.apk` | **最终安装包**（161 MB，arm64-v8a / armeabi-v7a / x86 / x86_64，v2+v3 签名） |
| `out/game_touch.pck` | 打好补丁的资源包（原始资源 + 触屏层 + 修改后的 project.binary） |
| `touch/touch_controls.gd` | 触屏层源码（纯 GDScript 文本，运行时编译） |
| `touch/selftest.gd` | 触屏层自测脚本（注入测试包用） |
| `tools/pck.py` | Godot PCK v4 读写器 |
| `tools/ecfg_patch.py` | project.binary（ECFG）解析/改写 |
| `tools/inject.py` | 打包带补丁的 PCK |
| `tools/build_game.py` | 生成最终/测试两种 PCK |
| `tools/build_apk.py` | 生成已签名 APK |
| `assets/game_base.pck` | 原始资源包（Git LFS 托管） |

安装：`adb install out/ABUELA.apk`（或把 APK 传到手机点击安装，需允许「未知来源」）。

## 五、已验证 / 未验证

已验证：
- 重写的 PCK 能被 Godot 4.7.2 引擎正常加载（Linux 模板实跑，菜单→游戏→玩家生成全流程通过）
- 触屏层自测全绿：摇杆位移、松手停止、双指同时操作、水平/俯仰视角、6 个动作按钮、
  蹲下/起身、跳跃、点物品栏、音乐滑条（点击 + 拖动）、难度列表（点选 Nightmare）
- 菜单触摸链路：Play → PlayGame → 进入游戏
- APK：zip 完整性、`assets.sparsepck` 460 条目全部通过 size+md5 校验、apksigner v2/v3 签名验证通过、
  图标与名称已替换

未验证（需要真机）：
- 真机安装与运行（本机无 Android 设备/模拟器）
- 真机帧率、显存占用与发热
- 部分 HUD/菜单在手机分辨率下的观感

## 六、后续可调项

`touch/touch_controls.gd` 顶部常量：
`JOY_RADIUS`（摇杆半径）、`JOY_SMOOTH`/`KNOB_SMOOTH`（摇杆平滑度，值越大越跟手）、
`AUTO_RUN`/`RUN_THRESHOLD`（自动冲刺）、`PITCH_LIMIT`（俯仰限位）、
`LOOK_SCALE`（视角倍率，实际灵敏度再乘游戏自带的 `Global.mouse_sensitivity`）、
`BTN_R`（按钮半径）、`EDGE_MARGIN`/`ROW_GAP`（按钮组离屏幕边缘的距离与行距）、
`JOY_ZONE_X`/`LOOK_ZONE_X`（摇杆区与视角区的分界）。UI 整体缩放按 `min(宽/1152, 高/648)` 自适应。

重新出包：

```bash
python3 tools/build_game.py          # 生成 out/game_touch.pck
python3 tools/build_apk.py           # 生成并签名 out/ABUELA.apk
```
