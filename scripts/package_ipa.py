"""Package the archived app as an unsigned IPA and check its contents."""
from pathlib import Path
import plistlib
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / "build/HTMLViewer.xcarchive/Products/Applications/HTMLViewer.app"
if not app.is_dir():
    sys.exit("The archive does not contain HTMLViewer.app. Read the archive log.")
info = plistlib.loads((app / "Info.plist").read_bytes())
executable = app / info["CFBundleExecutable"]
if not executable.is_file() or executable.stat().st_size < 100_000:
    sys.exit("The app executable is missing or empty.")
if not (app / "Assets.car").is_file():
    sys.exit("The asset catalog (app icon) is missing.")
out = root / "build/Download"
out.mkdir(parents=True, exist_ok=True)
name = "HTML-Viewer.ipa"
with zipfile.ZipFile(out / name, "w", zipfile.ZIP_DEFLATED) as z:
    for file in sorted(app.rglob("*")):
        if file.is_file():
            z.write(file, Path("Payload/HTMLViewer.app") / file.relative_to(app))
families = info.get("UIDeviceFamily")
if sorted(families or []) != [1, 2]:
    sys.exit(f"The app must support iPhone and iPad, found device families {families}.")
print(f"Created {name} (unsigned): device families {families}, {info['CFBundleIdentifier']} {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
      f"min iOS {info.get('MinimumOSVersion')}, executable {executable.stat().st_size} bytes")
