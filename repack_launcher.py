#!/usr/bin/env python3
"""v4 IPA -> v4.1: 只替换 Payload/DmIOS.app/dm/launcher.json 为汉化版，其余条目原样流式拷贝"""
import sys, zipfile, importlib.util, time

SRC = '/root/game-transfer/dump/SuperMarioPartyJamboree.ipa'
DST = '/root/game-transfer/dump/SuperMarioPartyJamboree-v4.1-zh.ipa'
ENTRY = 'Payload/DmIOS.app/dm/launcher.json'

spec = importlib.util.spec_from_file_location('nxkit', '/root/nxkit/nxkit.py')
nxkit = importlib.util.module_from_spec(spec); spec.loader.exec_module(nxkit)

zin = zipfile.ZipFile(SRC)
new_launcher = nxkit.translate_launcher_json(zin.read(ENTRY))
assert b'\xe6\xb8\xb8\xe6\x88\x8f' in new_launcher  # '游戏' UTF-8 存在性断言

n = 0
with zipfile.ZipFile(DST, 'w') as zout:
    for info in zin.infolist():
        zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        zi.compress_type = info.compress_type
        zi.external_attr = info.external_attr
        zi.internal_attr = info.internal_attr
        zi.create_system = info.create_system
        data = new_launcher if info.filename == ENTRY else None
        if data is not None:
            zout.writestr(zi, data, compress_type=info.compress_type)
        else:
            with zin.open(info) as f, zout.open(zi, 'w', force_zip64=info.file_size >= 1 << 31) as o:
                while True:
                    chunk = f.read(16 << 20)
                    if not chunk: break
                    o.write(chunk); n += len(chunk)
                    if n % (1 << 30) < (16 << 20): print(f'~{n>>30} GiB copied', flush=True)
zin.close()
print('DONE', DST)
