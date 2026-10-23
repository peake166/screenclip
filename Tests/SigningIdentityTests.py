"""Check that two versions of this app satisfy each other's signing requirements."""
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

app = Path(sys.argv[1]).resolve()
details = subprocess.run(["codesign", "-d", "-vv", str(app)], capture_output=True, text=True, check=True).stderr
if "Signature=adhoc" in details:
    identity = "-"
else:
    identity = re.search(r"^Authority=(.+)$", details, re.M).group(1)

def requirement(path):
    result = subprocess.run(["codesign", "-d", "-r-", str(path)], capture_output=True, text=True, check=True)
    output = result.stdout + result.stderr
    return re.search(r"designated => (.+)", output).group(1)

with tempfile.TemporaryDirectory(prefix="screenclip-signing-", dir=app.parent) as temporary:
    next_version = Path(temporary) / "NextVersion.app"
    shutil.copytree(app, next_version)
    info_file = next_version / "Contents/Info.plist"
    info = plistlib.loads(info_file.read_bytes())
    info["CFBundleVersion"] += ".1"
    info_file.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", identity, str(next_version)], check=True, capture_output=True)
    for target, reference in [(next_version, app), (app, next_version)]:
        result = subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement(reference), str(target)], capture_output=True, text=True)
        if result.returncode:
            print("FAIL changing the app version invalidates its previous signing identity")
            sys.exit(1)
    print("PASS both app versions satisfy each other's identity requirements")
