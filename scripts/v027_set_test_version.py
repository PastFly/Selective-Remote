from pathlib import Path

path = Path("scripts/build_app.sh")
text = path.read_text(encoding="utf-8")
old = 'VERSION="0.26.0"\n# CFBundleVersion is an internal monotonically increasing identifier required\n# by macOS and the update comparator. It is deliberately not shown as part of\n# the public application version.\nBUILD_NUMBER="139"'
new = 'VERSION="0.27.0"\n# CFBundleVersion is an internal monotonically increasing identifier required\n# by macOS and the update comparator. It is deliberately not shown as part of\n# the public application version.\nBUILD_NUMBER="140"'
if text.count(old) != 1:
    raise SystemExit("build version block did not match exactly once")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
Path("scripts/v027_set_test_version.py").unlink(missing_ok=True)
Path(".github/workflows/v027-version-patch.yml").unlink(missing_ok=True)
