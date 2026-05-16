<div align="center">

<img src="docs/icon.png" width="140" alt="Pastique" />

# Pastique

**The clipboard tool macOS is missing.**

Press `⌘⇧V`. See everything you've copied. That's it.

[![Release](https://img.shields.io/github/v/release/yiyu0x/pastique?display_name=tag&sort=semver)](../../releases/latest)
[![Downloads](https://img.shields.io/github/downloads/yiyu0x/pastique/total?color=brightgreen)](../../releases)
[![License](https://img.shields.io/github/license/yiyu0x/pastique)](LICENSE)

</div>

## Why Pastique

- **Auto-sorted clipboard** — colors, links, commands, personal info, and more are detected and grouped into categories so you can find them at a glance.
- **Just start typing to search** — no extra keystroke, no mode switch. Works smoothly with Chinese, Japanese, and Korean input too.
- **Light and fast** — built in Swift, a few MB on disk, no background drag on your Mac.

## Install

1. Download the latest `Pastique-*.zip` from the [Releases page](../../releases).
2. Unzip and drag `Pastique.app` to `/Applications`.
3. Open it once. macOS will show **"Apple could not verify Pastique."** To allow:
   - Open **System Settings → Privacy & Security**
   - Scroll to the **Security** section
   - Click **Open Anyway** next to the Pastique notice, confirm in the dialog
   - One-time per install. After this, future versions auto-update silently.

## Use

| | |
|---|---|
| Open clipboard history | `⌘⇧V` |
| Move selection | `↑` `↓` or hover with mouse |
| Copy selection to clipboard | `Enter` (then `⌘V` in your target app) |
| Cancel | `Esc` |
| Settings | Click `⚙` in the picker, or the menubar icon |

Supports text, images, and files. Stores the last 500 items. Sensitive content from password managers is automatically skipped.

## Support

If Pastique is useful to you, you can buy me a coffee — it's appreciated, not expected.

<a href="https://www.buymeacoffee.com/kylechang"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="40" /></a>

## License

MIT — see [LICENSE](LICENSE). Bug reports and PRs welcome; see [DEVELOPMENT.md](DEVELOPMENT.md) if you want to hack on Pastique.
