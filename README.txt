Selective Remote emergency RDP Retina display fix

Apply from the repository root:
  ditto -x -k ~/Downloads/SelectiveRemote-emergency-rdp-retina-fix.zip .
  python3 scripts/apply_selective_remote_rdp_retina_fix.py

Then verify:
  git diff --check
  swift test
  swift build -c release

This hotfix changes only:
  Sources/SelectiveRemote/FreeRDPService.swift
  Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift

It does not change VERSION/BUILD_NUMBER or release manifests.
