import Testing
@testable import MacSweepCore

struct DockerInfoTests {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    actor CommandRecorder {
        private var invocations: [Invocation] = []

        func record(executable: String, arguments: [String]) {
            invocations.append(Invocation(executable: executable, arguments: arguments))
        }

        func recordedInvocations() -> [Invocation] {
            invocations
        }
    }

    @Test func missingDockerSkipsEveryProbe() async {
        let recorder = CommandRecorder()

        let info = await DockerInfo.current(
            dockerPath: { nil },
            commandRunner: { executable, arguments in
                await recorder.record(executable: executable, arguments: arguments)
                return ProcessResult(status: 0, output: "", error: "")
            }
        )

        #expect(!info.isInstalled)
        #expect(!info.isRunning)
        #expect(info.containers == 0)
        #expect(info.images == 0)
        #expect(info.volumes == 0)
        #expect(await recorder.recordedInvocations().isEmpty)
    }

    @Test func successfulProbesUseExactArgvAndReportCounts() async {
        let recorder = CommandRecorder()

        let info = await DockerInfo.current(
            dockerPath: { "/test/bin/docker" },
            commandRunner: { executable, arguments in
                await recorder.record(executable: executable, arguments: arguments)
                let output: String
                switch arguments {
                case ["container", "ls", "-aq"]:
                    output = "container-a\ncontainer-b\n"
                case ["image", "ls", "-q"]:
                    output = "image-a\n"
                case ["volume", "ls", "-q"]:
                    output = ""
                default:
                    output = ""
                }
                return ProcessResult(status: 0, output: output, error: "")
            }
        )

        #expect(info.isInstalled)
        #expect(info.isRunning)
        #expect(info.containers == 2)
        #expect(info.images == 1)
        #expect(info.volumes == 0)
        #expect(await recorder.recordedInvocations() == [
            .init(executable: "/test/bin/docker", arguments: ["info"]),
            .init(executable: "/test/bin/docker", arguments: ["container", "ls", "-aq"]),
            .init(executable: "/test/bin/docker", arguments: ["image", "ls", "-q"]),
            .init(executable: "/test/bin/docker", arguments: ["volume", "ls", "-q"])
        ])
    }

    @Test func unavailableDaemonStopsBeforeCountProbes() async {
        let recorder = CommandRecorder()

        let info = await DockerInfo.current(
            dockerPath: { "/test/bin/docker" },
            commandRunner: { executable, arguments in
                await recorder.record(executable: executable, arguments: arguments)
                return ProcessResult(status: 1, output: "", error: "daemon unavailable")
            }
        )

        #expect(info.isInstalled)
        #expect(!info.isRunning)
        #expect(info.containers == 0)
        #expect(info.images == 0)
        #expect(info.volumes == 0)
        #expect(await recorder.recordedInvocations() == [
            .init(executable: "/test/bin/docker", arguments: ["info"])
        ])
    }

    @Test func failedCountProbesReturnZeroWithoutTrustingPartialOutput() async {
        let info = await DockerInfo.current(
            dockerPath: { "/test/bin/docker" },
            commandRunner: { _, arguments in
                switch arguments {
                case ["info"]:
                    return ProcessResult(status: 0, output: "", error: "")
                case ["container", "ls", "-aq"]:
                    throw ProcessRunnerError.launchFailed("launch failed")
                case ["image", "ls", "-q"]:
                    return ProcessResult(status: 1, output: "misleading-image\n", error: "failed")
                case ["volume", "ls", "-q"]:
                    throw ProcessRunnerError.timedOut(
                        after: 30,
                        partialResult: ProcessResult(
                            status: 0,
                            output: "misleading-volume\n",
                            error: ""
                        )
                    )
                default:
                    return ProcessResult(status: 0, output: "", error: "")
                }
            }
        )

        #expect(info.isInstalled)
        #expect(info.isRunning)
        #expect(info.containers == 0)
        #expect(info.images == 0)
        #expect(info.volumes == 0)
    }
}
