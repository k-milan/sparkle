# Sparkle

Sparkle is a native macOS menu-bar companion for the ChatGPT desktop app. It
uses local, event-driven Codex session records to notify you when a response is
ready or a task needs attention.

## Features

- One native notification per completed response
- Task titles in notifications
- Direct notification sound
- Pink tray state while something is waiting; white when acknowledged
- Automatically acknowledges alerts when ChatGPT is activated
- Kernel file notifications with effectively zero idle CPU polling
- No network requests and no API key

## Build and run

```sh
make bundle
open outputs/Sparkle.app
```

On first launch, allow notifications when macOS asks. Choose **Send Test Alert**
from the tray menu to verify banners and sound.

Sparkle reads append-only event records under `~/.codex/sessions` and resolves
task titles from the local Codex catalog. It does not modify those records or
send conversation data over the network.
