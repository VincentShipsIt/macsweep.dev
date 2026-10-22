import Foundation

extension MacSweepHeadlessService {
    public func doctor() async -> HeadlessDoctorReport {
        await EnvironmentDoctorService().scan().report
    }
}
