# Developer storage and cleanup

These workflows ship in MacSweep v1.2.0. Settings → Developer → Developer mode
reveals their sidebar entries. App Leftovers and Updates remain available under
Applications. The current published binary's scope is documented separately in
[release notes](../releases/v1.2.0.md).

| Page | Inspect and review |
| --- | --- |
| [Developer Disk Map](disk-map.md) | Bounded known-root scans, optional home scope, cached/partial coverage and typed links to owning reviews. The map performs no cleanup. |
| [Stale Projects](stale-projects.md) | Repository/source/artifact estimates, independent safe artifact sweeps, verified ZIP archives and separately reviewed checkout Trash. |
| [Xcode Deep Clean](xcode-cleanup.md) | Runtime/device ownership and activity, symbols, archives, previews and old application bundles. Available or uncertain native state stays retained. |
| [Toolchains](toolchains.md) | Installed versions, global/project references and activity before exact supported native uninstall. |
| [Environment Doctor](environment-doctor.md) | Orphan launch items, broken bin links, login PATH and Homebrew doctor. Only exact reviewed files/links can move to Trash. |
| [Local Snapshots](local-snapshots.md) | Startup-volume Time Machine inventory and explicitly reviewed bounded thinning. Backup history tradeoffs and permissions are shown first. |
| [Virtual Machines](virtual-machines.md) | Persistent manager/app-owned state and native activity. Only a narrowly verified Lima capability offers native removal; other data stays retained. |
| [IDE & Editor Caches](editor-caches.md) | Exact stale JetBrains caches, dead local workspaces, obsolete extensions and known Electron caches. Current versions, settings, Local History and running owners stay retained. |
| [App Leftovers](app-leftovers.md) | Metadata-grounded ownership and freshness checks for removed apps; uncertain/shared ownership stays retained. |
| [Updates](updates.md) | Manual detected-source checks, command review, bounded live output and independent per-package outcomes. App Store updates require explicit sign-in and administrator acknowledgements. |

Generic cache, AI, disk-map Trash and shred routes cannot bypass dedicated editor,
installed-runtime or persistent native-environment ownership checks. Explicit app
uninstallation remains its own whole-app review. A filename such as Cache, build
or target does not make persistent developer state disposable.

Heavy filesystem walks and read-only native sizing pipelines share two async
admission slots. Native command lifecycles have a separate eight-slot limit so
waiting processes cannot starve their pipe readers during bursts. Queued work
suspends without occupying worker threads; cancellation removes queued work and
reaches active workers/process groups. Completed filesystem mutations keep their
receipts when cancellation arrives after their final commit check.

Target sizes are estimates. Trash does not recover free space until emptied;
observed volume changes include other activity and are reported independently.
Unknown, partial and shared sizes are labeled explicitly. No new workflow enters
Smart Care as an automatic destructive action.
