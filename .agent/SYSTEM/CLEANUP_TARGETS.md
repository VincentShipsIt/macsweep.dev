# MacSweep Cleanup Targets

## Service Workers
Chromium browsers and Electron apps store service workers at:
```
~/Library/Application Support/<app>/*/Service Worker/
```

Supported apps:
- Brave, Chrome, Arc, Edge, Opera, Vivaldi
- Discord, Slack, WhatsApp, Cursor, VS Code, Notion, Figma, Telegram

## System Caches
```
~/Library/Caches/           # App caches
~/Library/Logs/             # User logs
~/Library/Saved Application State/
```

## Browser Caches
Each browser profile contains:
- Cache/
- Code Cache/
- GPUCache/
- ShaderCache/

## Development Caches
- Xcode: DerivedData, Archives, iOS DeviceSupport
- Node: node_modules, .npm, .pnpm-store
- Python: __pycache__, pip cache
- Homebrew: $(brew --cache)

## Protected Paths (Never Delete)
- ~/Documents, ~/Desktop, ~/Pictures
- ~/.ssh, ~/.gnupg
- ~/Library/Keychains
- /System, /Applications, /usr
