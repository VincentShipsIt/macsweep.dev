## Task: Docker Cleanup Module

**ID:** task-013
**Label:** Docker Cleanup
**Description:** Clean Docker resources (containers, images, volumes, build cache).
**Type:** Feature
**Status:** Backlog
**Priority:** Medium
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
2-3 hours

### Deliverables

#### 1. DockerCleanupModule
```swift
struct DockerCleanupModule: ScanModule {
    let id = "docker"
    let name = "Docker"
    let description = "Containers, images, volumes, and build cache"
    let icon = "shippingbox.fill"

    var isDockerInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/bin/docker") ||
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker")
    }

    var isDockerRunning: Bool {
        // Check if Docker daemon is running
        // docker info 2>/dev/null
    }

    func scan() async throws -> [CleanupItem]
}
```

#### 2. Docker Resources
```swift
struct DockerResources {
    /// Stopped containers
    func stoppedContainers() async throws -> [DockerContainer] {
        // docker ps -a --filter "status=exited" --format json
    }

    /// Dangling images (untagged)
    func danglingImages() async throws -> [DockerImage] {
        // docker images -f "dangling=true" --format json
    }

    /// Unused images (not referenced by any container)
    func unusedImages() async throws -> [DockerImage] {
        // docker images --filter "dangling=false" --format json
        // Cross-reference with container images
    }

    /// Unused volumes
    func unusedVolumes() async throws -> [DockerVolume] {
        // docker volume ls -f "dangling=true" --format json
    }

    /// Build cache
    func buildCacheSize() async throws -> Int64 {
        // docker system df --format json
    }
}
```

#### 3. Models
```swift
struct DockerContainer: Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let created: Date
    let size: Int64?
}

struct DockerImage: Identifiable {
    let id: String
    let repository: String
    let tag: String
    let size: Int64
    let created: Date
}

struct DockerVolume: Identifiable {
    let name: String
    let driver: String
    let size: Int64?
}
```

#### 4. Cleanup Actions
```swift
struct DockerCleanup {
    /// Remove stopped containers
    func removeContainers(_ ids: [String]) async throws {
        // docker rm <id> <id> ...
    }

    /// Remove images
    func removeImages(_ ids: [String]) async throws {
        // docker rmi <id> <id> ...
    }

    /// Remove volumes
    func removeVolumes(_ names: [String]) async throws {
        // docker volume rm <name> ...
    }

    /// Prune build cache
    func pruneBuildCache() async throws {
        // docker builder prune -f
    }

    /// Full system prune (aggressive)
    func systemPrune(all: Bool = false) async throws {
        // docker system prune -f [--all]
    }
}
```

#### 5. Docker Desktop Data
```swift
struct DockerDesktopData {
    /// Docker Desktop VM disk (can be reclaimed)
    let vmDiskPath = URL(fileURLWithPath: "~/Library/Containers/com.docker.docker/Data/vms")

    /// Check if Docker Desktop is installed
    var isDockerDesktop: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Docker.app")
    }

    /// Reclaim disk space (Docker Desktop feature)
    func reclaimDiskSpace() async throws {
        // Requires Docker Desktop CLI or UI
    }
}
```

### Docker Cleanup Options

| Resource | Risk Level | Command |
|----------|------------|---------|
| Stopped containers | Low | docker rm |
| Dangling images | Low | docker rmi |
| Unused images | Medium | docker image prune -a |
| Unused volumes | High | docker volume prune |
| Build cache | Low | docker builder prune |
| System prune | High | docker system prune -a |

### Acceptance Criteria
- [ ] Detects if Docker is installed and running
- [ ] Lists all cleanable resources with sizes
- [ ] Allows selective cleanup
- [ ] System prune option with warning
- [ ] Works with both Docker Desktop and CLI Docker

### Dependencies
- TASK-002 (Core Scanning Engine)

### Notes
- Docker CLI must be available
- Docker daemon must be running
- Some operations can take a while
- Volume cleanup can cause data loss - require explicit confirmation
