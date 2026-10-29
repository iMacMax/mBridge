# mBridge

A monitor icon in your menu bar (Mac) or system tray (PC) that lets one computer's keyboard and mouse control another on the same network. Push the cursor off the edge of the screen where the other computer sits and it carries on over there, like two monitors.

Any mix works: **Mac to PC, PC to Mac, Mac to Mac, PC to PC.** Every computer runs the same app, and each one shows the others with an Apple or Windows logo next to its name.

## Install

**On a Mac** (needs macOS 27 and Xcode's command line tools, `xcode-select --install`):

1. Run `./build.sh` in this folder. It makes `mBridge.app`.
2. Open `mBridge.app`. If macOS blocks it: right-click it, choose Open, then Open again.
3. System Settings > Privacy & Security: turn on `mBridge` under **Input Monitoring** and **Accessibility**, and allow **Local Network**. The menu shows "Needs permission" until the first two are on.

**On a PC**, one command in PowerShell:

```powershell
irm https://raw.githubusercontent.com/iMacMax/mBridge/main/pc/install.ps1 | iex
```

It compiles mBridge with the C# compiler that ships with Windows, starts it, and sets it to start at login. A monitor icon appears in the system tray. Run it as administrator once to add the firewall rule automatically, or allow it on Private networks when Windows asks.

Without GitHub: copy the `pc` folder to the PC and run `install.ps1` from it.

## Using it

Computers find each other by themselves. Click the icon and you see every other computer with its logo.

- **Click a computer** to control it. Click it again to let go. That's it.
- **Cross over** by pushing the cursor against the edge where that computer sits, and back by pushing off its matching edge.
- **Position:** pick Left, Right, Above or Below. On a Mac you can also choose **Arrange…** and drag the other computer next to yours like in Displays settings. It snaps to the edge and to aligned corners.
- **Switch to …** in the menu jumps over without touching the edge.
- **Back to This Mac / PC** always works with ⌃⌥⌘Esc (Mac) or Ctrl+Alt+Win+Esc (PC).
- **Enter Address…** is only needed if a computer isn't found (for example on a different subnet).

A computer is either controlling or being controlled, never both: controlling another one stops being controlled, and the menu says "Controlled by …" while another computer has this one.

The cursor is hidden on a computer while the keyboard and mouse are on the other one. Touch the hidden computer's own mouse and it comes back.

Each computer remembers the first one that controls it and turns others away. **Forget Paired Computer** in the menu resets that.

## Keys

Between a Mac and a PC the shortcut keys follow what they do: Command on the Mac is Ctrl on the PC (so ⌘C copies), Control is the Windows key, Option is Alt. Mac to Mac and PC to PC keep every key as it is. Scrolling follows the scroll direction of the computer you are typing on.

## Clipboard

Copy text on one computer and paste it on the other, whichever one you are using. Only text copied after connecting is shared. Copies marked secret by password managers are skipped. Images and files are not shared.

## Notes

- Same keyboard layout on both is assumed (keys are sent as physical keys).
- Windows blocks input from normal programs to elevated windows, the lock screen and Ctrl+Alt+Del.
- Rebuilding `mBridge.app` can make macOS forget its permissions. Remove and re-add it if switching stops working.
- A PC controlling something has no Arrange window; it uses the Position menu.
- Your position is saved automatically, per computer.

## License

MIT, see [LICENSE](LICENSE).
