# Sparkle

Sparkle is a native macOS menu-bar companion for the ChatGPT and Claude desktop
apps. It uses their local, event-driven records to notify you when a response is
ready or a task needs attention.

## Features

- One native notification per completed response
- Task titles in notifications
- Direct notification sound
- Pink tray state while something is waiting; white when acknowledged
- Sparkle mascot poses for idle, replied, attention, and offline states
- Sparkle app artwork on macOS notifications
- Automatically acknowledges alerts when ChatGPT or Claude is activated
- Kernel file notifications with effectively zero idle CPU polling
- No network requests and no API key

## Build and run

```sh
make bundle
open outputs/Sparkle.app
```

On first launch, allow notifications when macOS asks. Choose **Send Test Alert**
from the tray menu to verify banners and sound.

For ChatGPT, Sparkle reads append-only records under `~/.codex/sessions` and
resolves task titles from the local Codex catalog. For Claude, it watches
Claude's local log and resolves titles from Claude's local session metadata.
It does not modify those records or send conversation data over the network.
