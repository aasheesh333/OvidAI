import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
for p in (HERE, HERE.parents[2], HERE.parents[2] / 'ops' / 'image-edit-shim'):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))
