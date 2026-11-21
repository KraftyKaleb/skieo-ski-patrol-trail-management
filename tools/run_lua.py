"""Run a Lua 5.4 test script with lupa (when no `lua` binary is available).

Usage: python tools/run_lua.py tests/test_rules.lua

The script gets `arg` (its own path) and `MODS_DIR`: a temporary UE4SS
Mods folder holding a copy of this mod as Mods/ski-patrol-trail-management/Scripts, so tests never write into the
project folder.
"""
import shutil
import sys
import tempfile
from pathlib import Path
from lupa import lua54

root = Path(__file__).resolve().parent.parent
script = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as temp:
    mods = Path(temp) / 'Mods'
    shutil.copytree(root / 'Scripts', mods / 'ski-patrol-trail-management' / 'Scripts')
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute('package.path = ...', f'{mods}/ski-patrol-trail-management/Scripts/?.lua;' + lua.eval('package.path'))
    lua.globals().arg = str(script)
    lua.globals().MODS_DIR = str(mods) + '/'
    lua.execute(script.read_text())
print(f'ok {script.name}')
