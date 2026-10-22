# Xcode Deep Clean

The dedicated `XcodeCleanupView` inventories six storage categories and starts with no selection. It does not register targets with Smart Care or the general cleanup scanner. A typed service owns the operations; the shared cleanup review presents the exact selected targets and each mechanism before dispatch.

| Category | Inventory and size | Removal and retention |
| --- | --- | --- |
| Runtime images | `xcrun simctl runtime list -j`, cross-checked against `simctl list -j`; native `sizeBytes` | Exact UUID with `simctl runtime delete`. Only explicitly unavailable, deletable runtimes in a recognized state and storage location qualify. Available/unknown runtimes and runtimes with any simulator devices stay. |
| Simulator devices | `simctl list -j`; allocated-byte walk of the exact default device directory | Exact UUID with `simctl delete`. Only explicitly unavailable, Shutdown devices qualify. Available, booted, custom-location and unknown devices stay. |
| Device support | Direct entries in user iOS/watchOS/tvOS DeviceSupport directories | Explicit review then Trash. Entries modified within 90 days or with unknown age stay. Modification time is never labeled as proven last use. Symbols may need downloading again. |
| Archives | Date directories in the user's Archives location; archive application identity and CreationDate from Info.plist | Explicit review then Trash. Keep every newest archive per application, including tied dates. Unknown archive identities/dates stay. |
| Preview and simulator caches | Direct entries in user Xcode/UserData/Previews and CoreSimulator/Caches; bounded read-only inventory of system CoreSimulator/Caches | Explicit review then Trash, subject to the same 90-day retention and activity gates. System-owned caches are always retained with an explicit authority reason. |
| Xcode applications | Direct Xcode*.app installs in system/user Applications; bundle identifier must be com.apple.dt.Xcode | Explicit review then Trash. The selected developer application stays. Unknown selection stays. No admin escalation or permanent-delete fallback. |

File sizes are allocated bytes, including hidden files and directories, with hard-linked inodes counted once per target. The scan never follows links outside an application bundle. An unreadable, linked, special, changing or oversized tree receives an explicit retention reason and an unavailable size instead of a partial total. Each tree inspection is bounded by 500,000 nodes and 20 seconds. App-contained symlinks are inspected without traversal and must resolve inside the bundle.

No process is stopped. Runtime deletion requires every inventoried simulator globally to be Shutdown, and native state is re-inventoried immediately before each exact command. Xcode, Simulator, preview or compiler activity, an open target, or an incomplete developer-process snapshot retains affected targets. Immediately before each operation the service refreshes inventory, policy, selection, target identity, content evidence and activity. User protection rules cover native storage aliases as well as file descendants. The configured DeletionGuard cap is checked for the complete reviewed selection before any dispatch and again cumulatively across the run; confirmation does not bypass that cap.

Native commands are fixed argv calls through ProcessRunner with timeouts and cancellation. Installed help must expose the expected exact-target interfaces. UUID parsing excludes broad selectors such as `all` and `unavailable`. Native deletion is counted only after successful exit and a complete fresh inventory proves the exact identifier disappeared. Native failures never cause filesystem deletion. A partial receipt retains failures independently of successful targets.

Trash bytes are reported separately from native removed scope; they are not claimed as immediately freed space. Native image size is reported as processed target scope, not causally freed bytes. Before/after available-volume observations are attached separately and include concurrent activity.

The feature does not manage downloads, connected-device contents, system-owned cache directories, or install/uninstall Xcode components with administrator privileges. When Xcode/simctl is missing, unavailable inventory is reported and the page remains usable for independently inspectable user-owned targets.

## Verification

Verification (local): focused `XcodeCleanup` SwiftPM tests use owned directories, injected native commands, injected activity and injected Trash. They cover all categories, native command failure, exact identifiers, retained states, changed content/selection/rules, cap enforcement and partial receipts. No real Xcode artifacts, simulator devices, runtime images or processes are modified by these tests.

Apple documents component ownership and removal in [Downloading and installing additional Xcode components](https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components). Native command syntax and the warning that runtime deletion can shut down booted devices were checked against installed `simctl help runtime` and `simctl help delete`; MacSweep requires its own fresh inactivity checks before dispatch.
