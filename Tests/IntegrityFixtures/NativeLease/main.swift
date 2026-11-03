import Foundation
let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SR_LEASE_TEST_DIR"]!, isDirectory: true)
do {
    let lease = try NativeStorageLease(directory: directory)
    print("LEASE_ACQUIRED")
    fflush(stdout)
    if CommandLine.arguments.contains("hold") { sleep(30) }
    withExtendedLifetime(lease) {}
} catch NativeStorageLease.LeaseError.busy {
    print("LEASE_BUSY")
    exit(3)
} catch {
    print("LEASE_FAILURE")
    exit(4)
}
