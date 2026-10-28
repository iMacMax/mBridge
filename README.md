# mBridge

A monitor icon in your menu bar that lets this Mac's keyboard and mouse control a Windows PC on the same network. Push the cursor off the edge of the screen where the PC sits and it carries on over there, like two monitors.

## Install

**On the Mac** (needs macOS 27 and Xcode's command line tools, `xcode-select --install`):

1. Run `./build.sh` in this folder. It makes `mBridge.app`.
2. Open `mBridge.app`. If macOS blocks it: right-click it, choose Open, then Open again.
3. System Settings > Privacy & Security: turn on `mBridge` under **Input Monitoring** and **Accessibility**, and allow **Local Network**. The menu shows "Needs permission" until the first two are on.

**On the PC**, one command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/iMacMax/mBridge/main/pc/install.ps1 | iex
```

It compiles mBridge with the C# compiler that ships with Windows, starts it, and sets it to start at login. A monitor icon appears in the system tray. Run it as administrator once to add the firewall rule automatically, or allow it on Private networks when Windows asks.

Without GitHub: copy the `pc` folder to the PC and run `install.ps1` from it.

## Using it

The Mac finds the PC by itself (the PC announces itself on the network) and connects. The icon is dim until it does.

- **Position:** pick Left, Right, Above or Below, or choose **Arrange…** and drag the PC next to your Mac like in Displays settings. It snaps to the edge and to aligned corners.
- **Switch:** push the cursor against the edge where the PC sits. To come back, push it off the PC's matching edge.
- **Switch to PC** in the menu jumps over without touching the edge.
- **Back to Mac** always works with ⌃⌥⌘Esc.
- **PC > Enter Address…** is only needed if the PC isn't found (for example on a different subnet).

The first Mac to connect is remembered by the PC and any other Mac is turned away. **Forget Paired Mac** in the PC's tray menu resets that.

## Keys

Command is Ctrl on the PC (so ⌘C copies), Control is the Windows key, Option is Alt. Scrolling follows your Mac's scroll direction setting.

## Notes

- Same keyboard layout on both is assumed (keys are sent as physical keys).
- Windows blocks input from normal programs to elevated windows, the lock screen and Ctrl+Alt+Del.
- Clipboard and file sharing are not included.
- Rebuilding `mBridge.app` can make macOS forget its permissions. Remove and re-add it if switching stops working.
- Your position is saved automatically.

## License

MIT, see [LICENSE](LICENSE).
