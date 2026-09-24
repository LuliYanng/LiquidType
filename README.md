<h1 align="center">LiquidType</h1>

<p align="center">A native Mac AI voice typing tool with a <b>Liquid Glass</b> style.</p>

<p align="center"><a href="README.zh.md">中文说明</a></p>

<p align="center"><img src="Resources/hero.png" width="520" alt="LiquidType pill over the desktop"></p>

**Waveform mode** — just the bars:

https://github.com/user-attachments/assets/76607c91-3a24-44b4-87d9-a04542938314

**Text mode** — see the transcript as you speak:

https://github.com/user-attachments/assets/35b473eb-5f48-4b00-8fda-0aef27471312

## What's different

* The UI is built with Liquid Glass on macOS 26, trying to stay as close to the real liquid glass material as possible.
* While you talk, you can see the recognized text in real time.
* If you'd rather not watch the words, you can switch it to a simple waveform.

## Note

The Liquid Glass effect currently uses `_variant: 11` (frosted). Only tested on macOS 26.0 Beta (Tahoe) — other versions may not produce the same result.

## Setup

You need **macOS 26** for the Liquid Glass effect.

The download is built for **Apple Silicon** (M1 and later). It probably won't run on Intel Macs — if you're on Intel, try building from source instead.

### Download

<a href="https://github.com/LuliYanng/LiquidType/releases/latest/download/LiquidType.dmg"><img src="Resources/download-macos.png" width="190" alt="Download app for macOS"></a>

Once downloaded, open the `.dmg` and drag **LiquidType** into **Applications**.

> [!IMPORTANT]
> I don't have a paid Apple Developer account, so the app isn't notarized. On first launch macOS will say it *can't verify LiquidType is free of malware*. That's expected.
>
> You need to let it through once per downloaded version. Pick one of the two ways below.

#### Recommended: Terminal

One command, works every time:

```bash
xattr -dr com.apple.quarantine /Applications/LiquidType.app
```

Then open LiquidType normally.

#### Or: System Settings

> [!NOTE]
> This needs an admin account. If it doesn't work, use the Terminal command above.

1. Open LiquidType — you'll get the warning. Click **Done**.
2. Go to **System Settings → Privacy & Security**.
3. Scroll to the bottom and click **Open Anyway** next to the LiquidType message.
4. Confirm with your password or Touch ID.

### Build from source

You'll need Xcode Command Line Tools.

```bash
git clone https://github.com/LuliYanng/LiquidType.git
cd LiquidType
bash scripts/install_app.sh
```

### First launch

On first launch, go to:

**System Settings → Privacy & Security**

Grant LiquidType two permissions, then relaunch:

1. **Accessibility**: so it can listen for the `fn` key and type into the current app.
2. **Microphone**: for recording.

Also turn off the system function for `fn`:

**System Settings → Keyboard → *Press fn key* → Do Nothing**

Last step — add an API key.

Click the menu bar icon → click **DashScope** → paste your API key → hit Return.

### API Keys

| Key                  | What it's for                          | Get one |
| -------------------- | -------------------------------------- | ------- |
| `DASHSCOPE_API_KEY`  | Qwen speech recognition + cleanup      | [Qwen platform](https://platform.qianwenai.com/home/api-keys) |
| `OPENROUTER_API_KEY` | Claude Haiku cleanup, optional         | [OpenRouter](https://openrouter.ai/settings/keys) |
| `CARTESIA_API_KEY`   | Cartesia English recognition, optional | [Cartesia](https://play.cartesia.ai/keys) |

You only need `DASHSCOPE_API_KEY` to get started. The app talks to the China-region DashScope endpoint, so a key from the international Model Studio (Singapore) won't work.

## Usage

Pretty simple:

* Tap `fn` to start talking.
* Tap `fn` again to finish — the text gets typed into your current app.
* Press `esc` while recording to cancel.
* Click the menu bar icon → **Panel** to switch between text / waveform, change the speech model or cleanup LLM, and manage API keys.

## Why I made this

I really like the Liquid Glass look on macOS 26, but most voice typing tools don't look that great. I just wanted a voice input tool on macOS that actually looks good.

## License

MIT
