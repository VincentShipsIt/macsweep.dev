## Task: iOS Companion App

**ID:** task-015
**Label:** iOS Companion App
**Description:** Create an iOS companion app for MacSweep that provides device storage management and syncs with the macOS app.
**Type:** Feature
**Status:** Backlog
**Priority:** Medium
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
2-3 weeks

### Platform Differences

| Feature | macOS | iOS |
|---------|-------|-----|
| System cleanup | Full access | Sandboxed |
| App uninstall | Yes | No (system only) |
| Cache clearing | All apps | Own app only |
| Storage analysis | Full disk | Photos/Videos/Documents |
| Background monitoring | Yes | Limited |

### iOS-Specific Features

#### 1. Photo & Video Cleanup
- Find duplicate photos
- Identify similar photos (AI-based)
- Find large videos
- Clear screenshots
- Remove Live Photo video portions
- Detect blurry photos

#### 2. Document Management
- Find large files in Files app
- Identify old downloads
- Clean document duplicates

#### 3. App Storage Insights
- Show storage per app (system API)
- Suggest offloading unused apps
- Clear Safari data

#### 4. iCloud Management
- Show iCloud storage usage
- Identify what's taking space
- Optimize local storage

#### 5. Device Health
- Battery health display
- Storage breakdown
- RAM usage (limited API)

### Technical Architecture

```
MacSweepIOS/
├── MacSweepIOS/
│   ├── App/
│   │   ├── MacSweepApp.swift
│   │   └── AppState.swift
│   ├── Features/
│   │   ├── PhotoCleanup/
│   │   ├── Storage/
│   │   ├── Settings/
│   │   └── Widgets/
│   ├── Core/
│   │   ├── PhotoAnalyzer/
│   │   ├── StorageAnalyzer/
│   │   └── DuplicateFinder/
│   └── Extensions/
│       └── WidgetExtension/
└── Package.swift
```

### Key APIs

| Feature | API |
|---------|-----|
| Photos | PhotoKit (PHAsset, PHImageManager) |
| Storage | FileManager + URL.resourceValues |
| iCloud | FileManager.ubiquityIdentityToken |
| App storage | Settings URL scheme |
| Background | BGTaskScheduler |

### Widgets

#### Home Screen Widget
- Storage summary (used/free)
- Quick cleanup button
- Photo count to review

#### Lock Screen Widget
- Storage percentage
- "X items to clean" badge

### Sync with macOS (Future)

- CloudKit for preferences sync
- Handoff for continuing tasks
- Share cleanup reports

### Acceptance Criteria
- [ ] Photo duplicate detection works
- [ ] Storage analysis accurate
- [ ] Widgets display correctly
- [ ] App Store guidelines compliant
- [ ] Privacy-focused (no data collection)

### App Store Considerations

1. **Cannot claim to "clean" the device** - Apple restricts this language
2. **Focus on organization** - "Organize photos", not "clean storage"
3. **No system access** - Only user's own data
4. **Privacy** - All analysis on-device, no cloud processing

### References
- [Gemini Photos](https://apps.apple.com/app/gemini-photos/id1277110040) - Photo cleanup reference
- [CleanMyMac Mobile](https://macpaw.com/cleanmymac-mobile) - Limited iOS version
