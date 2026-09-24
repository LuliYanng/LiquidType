# LiquidType

一个 **Liquid Glass** 风格的 Mac原生 AI语音输入工具。

[English](README.md)

**文字模式**——说话时实时看到识别结果：

https://github.com/user-attachments/assets/8fb16a30-2509-44ef-872d-cc1431573fdf

**波形模式**——只显示波形：

https://github.com/user-attachments/assets/76607c91-3a24-44b4-87d9-a04542938314

## 有什么不一样

* 用 macOS 26 的 Liquid Glass 做的UI，尽量还原系统本身的液态玻璃效果。
* 说话的时候能够实时看到识别出来的文字。
* 如果不想看文字，也可以切成简单的波形显示。

## 注意

目前 Liquid Glass 效果用的是 `_variant: 11`（frosted），只在 macOS 26.0 Beta (Tahoe) 上测试过，其他版本暂不确定能否实现相同效果。

## 安装

需要 **macOS 26** 才能用 Liquid Glass 效果。

打包好的版本只支持 **Apple Silicon**（M1 及以后的芯片），Intel 芯片的 Mac 大概率打不开，可以试试从源码编译。

### 下载安装

<a href="https://github.com/LuliYanng/LiquidType/releases/latest/download/LiquidType.dmg"><img src="Resources/download-macos.png" width="190" alt="下载 macOS 版"></a>

下载完成后，打开 `.dmg`，把 **LiquidType** 拖进「应用程序」。

> [!IMPORTANT]
> 我没有付费的苹果开发者账号，所以 App 没做公证。第一次打开时，系统会提示「无法验证 LiquidType 是否包含恶意软件」，这是正常现象。
>
> 每下载一个新版本，需要放行一次。下面两种方法选一种就行。

#### 推荐：终端

一行命令，每次都有效：

```bash
xattr -dr com.apple.quarantine /Applications/LiquidType.app
```

然后正常打开 LiquidType 就行。

#### 或者：系统设置

> [!NOTE]
> 这个方法需要管理员账户。如果不行，就用上面的终端命令。

1. 打开 LiquidType，会弹出警告，点「完成」。
2. 打开 **系统设置 → 隐私与安全性**。
3. 拉到页面底部，在 LiquidType 那条提示旁边点 **仍要打开**。
4. 输入密码或用触控 ID 确认。

### 从源码编译

需要 Xcode Command Line Tools。

```bash
git clone https://github.com/LuliYanng/LiquidType.git
cd LiquidType
bash scripts/install_app.sh
```

### 首次启动

第一次启动后，需要在：

**系统设置 → 隐私与安全性**

给 LiquidType 两个权限，然后重启 App：

1. **辅助功能**：用来监听 `fn` 键，以及把文字输入到当前 App。
2. **麦克风**：用来录音。

另外记得把 `fn` 键的系统功能关掉：

**系统设置 → 键盘 →「按下 fn 键时」→ 不执行任何操作**

最后填一把 API Key 就可以用了。

点击菜单栏图标 → 点击 **DashScope** → 粘贴 API Key → 回车。

### API Key

| Key                  | 用途                 |
| -------------------- | ------------------ |
| `DASHSCOPE_API_KEY`  | 千问语音识别 + 千问润色      |
| `OPENROUTER_API_KEY` | Claude Haiku 润色，可选 |
| `CARTESIA_API_KEY`   | Cartesia 英文识别，可选   |

一般只需要 `DASHSCOPE_API_KEY` 就能跑起来。百炼国内站、国际站、美国站的 key 都能用，会自动识别是哪个站的。

## 用法

很简单：

* 按一下 `fn`，开始说话。
* 再按一下 `fn`，结束录音，文字会自动输入到当前 App。
* 录音过程中按 `esc` 可以取消。
* 点击菜单栏图标 → **面板**，可以切换文字 / 波形、识别模型和润色 LLM，也可以修改 API Key。

## 为什么做这个

我自己很喜欢 macOS 26 的 Liquid Glass效果，但现在大部分语音输入工具都不太好看，因此想做一个在 macOS 上好看的语音输入。

## 许可

MIT
