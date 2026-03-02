# MacSweep Development Roadmap

## Current Status

### Completed ✅
- [x] Project structure (Swift + SwiftUI)
- [x] CleanMyMac-style UI with grouped sidebar
- [x] Welcome screen with circular Scan button
- [x] System monitoring (CPU, RAM, Battery, Network)
- [x] Menu bar widget with live stats
- [x] System cache cleanup module
- [x] Duplicate file finder module
- [x] Safety checker (protected paths)
- [x] Purple gradient theme
- [x] Maintenance view UI

### In Progress 🔄
- [ ] Browser cleanup module
- [ ] App uninstaller

---

## Sprint 1: Core Cleanup (Next)

**Goal:** Deliver the highest-impact cleanup features

| Feature | Priority | Status | Task |
|---------|----------|--------|------|
| Browser Cleanup | P0 | 🔲 TODO | TASK-005 |
| App Uninstaller | P0 | 🔲 TODO | TASK-007 |
| Large Files Finder | P1 | 🔲 TODO | TASK-009 |
| Maintenance Backend | P1 | 🔲 TODO | TASK-014 |

**Deliverables:**
- Chrome, Safari, Firefox, Brave cache cleaning
- Electron app service worker cleanup
- Complete app uninstall with leftover detection
- Find files > 100MB with Quick Look preview
- Working DNS flush, Spotlight rebuild

---

## Sprint 2: Visual Features

**Goal:** Add visual differentiation and developer tools

| Feature | Priority | Status | Task |
|---------|----------|--------|------|
| Space Lens | P1 | 🔲 TODO | TASK-008 |
| Developer Tools | P1 | 🔲 TODO | TASK-006 |
| Trash Bins | P2 | 🔲 TODO | - |

**Deliverables:**
- Sunburst disk visualization
- Drill-down folder navigation
- node_modules, DerivedData cleanup
- Global package cache cleanup
- Empty all trash bins

---

## Sprint 3: Speed & Protection

**Goal:** Complete Speed and Protection sections

| Feature | Priority | Status | Task |
|---------|----------|--------|------|
| Optimization | P2 | 🔲 TODO | - |
| Privacy Cleanup | P2 | 🔲 TODO | - |
| Mail Attachments | P2 | 🔲 TODO | - |

**Deliverables:**
- Memory management with process list
- Browser history/cookies clearing
- Recent documents clearing
- Mail attachment finder

---

## Sprint 4: Advanced & Polish

**Goal:** Package managers, Docker, polish

| Feature | Priority | Status | Task |
|---------|----------|--------|------|
| Package Managers | P3 | 🔲 TODO | TASK-012 |
| Docker Cleanup | P3 | 🔲 TODO | TASK-013 |
| Network Cleanup | P3 | 🔲 TODO | TASK-011 |
| Shredder | P3 | 🔲 TODO | - |

**Deliverables:**
- Homebrew, npm, pip, cargo cleanup
- Docker containers, images, volumes
- WiFi networks, SSH known_hosts
- Secure file deletion

---

## Sprint 5: iOS Companion

**Goal:** Launch iOS version

| Feature | Priority | Status | Task |
|---------|----------|--------|------|
| iOS App | P3 | 🔲 TODO | TASK-015 |

**Deliverables:**
- Photo duplicate detection
- Similar photo finder (AI)
- Large video finder
- Storage insights
- Home screen widgets

---

## Distribution Milestones

### Alpha (Internal Testing)
- [ ] Core cleanup features working
- [ ] No critical bugs
- [ ] Basic error handling

### Beta (Public Testing)
- [ ] All Phase 1-2 features
- [ ] Notarized for distribution
- [ ] GitHub releases set up

### v1.0 (Public Release)
- [ ] All Phase 1-3 features
- [ ] Homebrew cask formula
- [ ] Documentation complete
- [ ] Landing page

### v1.1 (iOS)
- [ ] iOS app on TestFlight
- [ ] CloudKit sync (optional)

---

## Technical Debt to Address

1. **Tests** - Add unit tests for modules
2. **Logging** - Add proper audit logging
3. **Config file** - User-configurable settings
4. **Localization** - i18n support
5. **Accessibility** - VoiceOver support

---

## Feature Requests Backlog

- [ ] Scheduled cleanup (weekly/monthly)
- [ ] Backup before delete option
- [ ] Undo last cleanup
- [ ] Export cleanup report
- [ ] Dark/light theme toggle
- [ ] Keyboard shortcuts
- [ ] Touch Bar support
- [ ] Siri Shortcuts integration
