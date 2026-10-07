#!/usr/bin/env python3
"""Exercise the launcher's real link repair without starting another BEAM."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[2] / 'bin/bl').read_text()
helper = source[source.index('ensure_image_link() {'):source.index('\nif [ -z "${BEAM_LISP_EBIN:-}" ]; then\n  IMAGE=')]
with tempfile.TemporaryDirectory(prefix='bl image links ') as tmp:
    root = Path(tmp)
    old = root / 'old'; old.mkdir()
    new = root / 'new'; new.mkdir()
    link = root / 'image'
    def repair():
        return subprocess.run(['sh', '-c', helper + '\nensure_image_link "$1" "$2"',
                               'test', str(new), str(link)], capture_output=True)
    assert repair().returncode == 0
    assert link.resolve() == new
    stamp = link.lstat().st_mtime_ns
    assert repair().returncode == 0 and link.lstat().st_mtime_ns == stamp
    link.unlink(); link.symlink_to(old)
    assert repair().returncode == 0 and link.resolve() == new
    link.unlink(); link.symlink_to(root / 'missing')
    assert repair().returncode == 0 and link.resolve() == new
    link.unlink(); link.mkdir(); (link / 'keep').write_text('untouched')
    assert repair().returncode != 0 and (link / 'keep').read_text() == 'untouched'
    assert not (link / 'new').exists()
print('7 image-link checks passed')
