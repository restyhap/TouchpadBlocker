# Touchpad Blocker

一款 macOS 菜单栏小工具，用于在打字时自动禁用触摸板，防止误触。

## 功能特点
- **智能防误触**：打字时自动屏蔽触摸板点击和移动，停止打字 0.5 秒后自动恢复。
- **静默运行**：无 Dock 图标，只在菜单栏显示 "TB" 状态图标。
- **开机自启**：支持设置开机自动启动。
- **原生极速**：基于 Swift 和底层 EventTap 开发，极低资源占用。

## 安装与使用

### 1. 构建应用
如果您下载的是源码，请运行以下命令生成应用：

```bash
chmod +x build_app.sh
./build_app.sh
```

这将会在当前目录下生成 `TouchpadBlocker.app`。

### 2. 运行
双击 `TouchpadBlocker.app` 即可运行。

### 3. 权限设置 (重要)
首次运行时，或者功能不生效时，请检查权限：
1. 打开 **系统设置** -> **隐私与安全性** -> **辅助功能**。
2. 确保 `TouchpadBlocker` 在列表中且已开启。
3. 如果看不到应用，请手动将 `.app` 拖入列表，或者先运行一次应用让系统捕获请求。

### 4. 菜单栏操作
在顶部菜单栏找到 "TB" 图标：
- **Status**: 显示当前是否处于工作状态，点击可暂停/恢复。
- **Start at Login**: 勾选后，应用将在登录时自动启动。
- **Quit**: 退出应用。

## 卸载
1. 在菜单栏点击 Quit 退出应用。
2. 删除 `TouchpadBlocker.app`。
3. 如果设置了开机自启，删除 `~/Library/LaunchAgents/com.resty.touchpadblocker.plist` (可选，系统也会自动忽略无效的 plist)。
