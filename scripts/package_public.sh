#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/dist"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$TMPDIR" "$OUTPUT"
cd "$ROOT"
swift build --package-path "$ROOT" -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT=."
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
python3 - "$ROOT" "$OUTPUT" "$BIN" <<'PY'
from pathlib import Path
import json, plistlib, shutil, sys
root, output, binary = map(Path, sys.argv[1:])
app = output / 'Pocket Transfer.app'
if app.exists(): shutil.rmtree(app)
mac = app / 'Contents/MacOS'
res = app / 'Contents/Resources'
mac.mkdir(parents=True)
res.mkdir()
shutil.copy2(binary / 'Osmotic', mac / 'Osmotic')
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
info.pop('PocketTransferWorkspaceRoot', None)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
for source, dest in [('LICENSE','LICENSE.txt'),('Resources/Credits.rtf','Credits.rtf'),('Resources/AppIcon.icns','AppIcon.icns'),('Resources/PrivacyInfo.xcprivacy','PrivacyInfo.xcprivacy'),('Resources/PublicQuickStart.txt','使用说明.txt')]:
    shutil.copy2(root/source, res/dest)
catalog = json.loads((root/'Resources/Localizable.xcstrings').read_text())
for lang in ['en','es']:
    folder = res / f'{lang}.lproj'
    folder.mkdir(exist_ok=True)
    strings = {}
    plurals = {}
    for key, entry in catalog['strings'].items():
        loc = entry.get('localizations',{}).get(lang,{})
        if 'stringUnit' in loc:
            strings[key] = loc['stringUnit']['value']
        elif 'variations' in loc and 'plural' in loc['variations']:
            spec = {'NSStringFormatSpecTypeKey':'NSStringPluralRuleType','NSStringFormatValueTypeKey':'lld'}
            spec.update({n: v['stringUnit']['value'] for n,v in loc['variations']['plural'].items()})
            plurals[key] = {'NSStringLocalizedFormatKey':'%#@count@','count':spec}
    (folder/'Localizable.strings').write_bytes(plistlib.dumps(strings))
    if plurals: (folder/'Localizable.stringsdict').write_bytes(plistlib.dumps(plurals))
for folder in (root/'Resources').glob('*.lproj'):
    shutil.copytree(folder,res/folder.name,dirs_exist_ok=True)
print(app)
PY
codesign --force --sign - --options runtime --entitlements "$ROOT/Resources/Osmotic.entitlements" --identifier dev.ly.pockettransfer "$OUTPUT/Pocket Transfer.app"
codesign --verify --deep --strict "$OUTPUT/Pocket Transfer.app"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUTPUT/Pocket Transfer.app/Contents/Info.plist")
ARCH=$(uname -m)
ZIP="Pocket-Transfer-${VERSION}-macOS-${ARCH}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$OUTPUT/Pocket Transfer.app" "$OUTPUT/$ZIP"
(cd "$OUTPUT" && shasum -a 256 "$ZIP" > SHA256SUMS.txt)
printf '%s\n' "$OUTPUT/$ZIP"
