import Testing
@testable import SelectiveRemote

@Test("Linux distributions resolve to distinct host identities", arguments: [
    ("ubuntu", "debian", "Ubuntu 24.04", ProfileOperatingSystemIdentity.ubuntu),
    ("debian", "", "Debian GNU/Linux 13", .debian),
    ("kali", "debian", "Kali GNU/Linux", .kali),
    ("astra", "debian", "Astra Linux", .astra),
    ("arch", "", "Arch Linux", .arch),
    ("manjaro", "arch", "Manjaro Linux", .manjaro),
    ("alpine", "", "Alpine Linux", .alpine),
    ("fedora", "", "Fedora Linux", .fedora),
    ("rhel", "fedora", "Red Hat Enterprise Linux", .redHat),
    ("centos", "rhel fedora", "CentOS Stream", .centOS),
    ("rocky", "rhel centos fedora", "Rocky Linux", .rocky),
    ("almalinux", "rhel centos fedora", "AlmaLinux", .alma),
    ("opensuse-leap", "suse opensuse", "openSUSE Leap", .suse)
])
func resolvesLinuxDistribution(
    osID: String,
    osLike: String,
    label: String,
    expected: ProfileOperatingSystemIdentity
) {
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .ssh,
            osID: osID,
            osLike: osLike,
            label: label
        ) == expected
    )
}

@Test("ID takes precedence over distro family")
func prefersSpecificDistributionOverIDLike() {
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .ssh,
            osID: "ubuntu",
            osLike: "debian",
            label: "Ubuntu 24.04 LTS"
        ) == .ubuntu
    )
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .ssh,
            osID: "rocky",
            osLike: "rhel centos fedora",
            label: "Rocky Linux 9.6"
        ) == .rocky
    )
}

@Test("Unknown Linux and undiscovered SSH stay visually distinct")
func resolvesGenericLinuxAndSSH() {
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .ssh,
            osID: "void",
            osLike: "linux",
            label: "Void Linux"
        ) == .linux
    )
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .ssh,
            osID: "",
            osLike: "",
            label: ""
        ) == .ssh
    )
}

@Test("Connection protocol keeps priority over stale OS metadata")
func protocolOverridesDetectedIdentity() {
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .rdp,
            osID: "ubuntu",
            osLike: "debian",
            label: "Ubuntu"
        ) == .windows
    )
    #expect(
        ProfileOperatingSystemIdentity.resolve(
            connectionType: .serial,
            osID: "linux",
            osLike: "",
            label: "Linux"
        ) == .serial
    )
}
