import zipfile, shutil, sys, os

SLIM = '/root/nxkit-home/dl/slim.ipa'
MASTER = '/root/game-transfer/d3_build/DiabloIII.ipa'
OUT = '/mnt/laptop-share/QuarkDownload/暗黑破坏神3/DiabloIII.ipa.partial'
FINAL = '/mnt/laptop-share/QuarkDownload/暗黑破坏神3/DiabloIII.ipa'
APP = 'Payload/DmIOS.app/'
KEEP_ZH = APP + 'dm/launcher.json'

slim = zipfile.ZipFile(SLIM)
master = zipfile.ZipFile(MASTER)
slim_names = set(slim.namelist())
master_names = set(master.namelist())

total = len(master.infolist())
done = 0
with zipfile.ZipFile(OUT, 'w', allowZip64=True) as out:
    # 1) master 全部条目：app 下（除保留的中文 launcher.json）用 slim 覆盖
    for it in master.infolist():
        src = master
        if it.filename.startswith(APP) and it.filename != KEEP_ZH and it.filename in slim_names:
            src = slim
        zi = zipfile.ZipInfo(it.filename, date_time=it.date_time)
        zi.compress_type = it.compress_type
        zi.external_attr = it.external_attr
        with src.open(it.filename) as f, out.open(zi, 'w') as g:
            shutil.copyfileobj(f, g, 1024 * 1024)
        done += 1
        if done % 100 == 0:
            print(f'merge: {done} of {total} entries', flush=True)
    # 2) slim 独有的 app 条目（新增文件）补进去
    added = 0
    for name in sorted(slim_names - master_names):
        if name.startswith(APP) and name != KEEP_ZH:
            si = slim.getinfo(name)
            zi = zipfile.ZipInfo(name, date_time=si.date_time)
            zi.compress_type = si.compress_type
            zi.external_attr = si.external_attr
            with slim.open(name) as f, out.open(zi, 'w') as g:
                shutil.copyfileobj(f, g, 1024 * 1024)
            added += 1
print(f'DONE entries={total}+added{added}', flush=True)

# 校验：条目数 + 大小
zo = zipfile.ZipFile(OUT)
nm, mm = zo.namelist(), master.namelist()
print(f'VERIFY out={len(nm)} master={len(mm)} missing={[x for x in mm if x not in set(nm)][:5]}', flush=True)
print(f'VERIFY size={os.path.getsize(OUT):,}', flush=True)
zo.close(); master.close(); slim.close()
os.replace(OUT, FINAL)
print('RENAMED to final', flush=True)
