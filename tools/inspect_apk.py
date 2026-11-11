#!/usr/bin/env python3
"""Read APK feature evidence without running Android code or interpreting its text as instructions."""
import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('apk', type=Path)
parser.add_argument('--output', type=Path, default=Path('audit'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
classes = set()
with zipfile.ZipFile(args.apk) as archive:
    for name in archive.namelist():
        if not name.endswith('.dex'):
            continue
        data = archive.read(name)
        count, offset = struct.unpack_from('<II', data, 56)
        strings = []
        for index in range(count):
            position = struct.unpack_from('<I', data, offset + index * 4)[0]
            while data[position] & 128:
                position += 1
            position += 1
            end = data.index(b'\0', position)
            strings.append(data[position:end].decode('utf-8', errors='replace'))
        count, offset = struct.unpack_from('<II', data, 96)
        _, types_offset = struct.unpack_from('<II', data, 64)
        for index in range(count):
            type_id = struct.unpack_from('<I', data, offset + index * 32)[0]
            string_id = struct.unpack_from('<I', data, types_offset + type_id * 4)[0]
            value = strings[string_id]
            if value.startswith('Lcom/myko/') and '$' not in value:
                classes.add(value)
    summary = {
        'apk': args.apk.name,
        'sha256': hashlib.sha256(args.apk.read_bytes()).hexdigest(),
        'app_classes_without_generated_lambdas': len(classes),
        'bundled_channels': len(json.loads(archive.read('assets/idan/channels.json'))),
        'android_native_libraries': sorted({name.split('/')[-1] for name in archive.namelist() if name.startswith('lib/') and name.endswith('.so')}),
    }
(args.output / 'dex-inventory.json').write_text(json.dumps(summary, indent=2) + '\n')
(args.output / 'myko-features.txt').write_text('\n'.join(sorted(classes)) + '\n')
print(json.dumps(summary, indent=2))
