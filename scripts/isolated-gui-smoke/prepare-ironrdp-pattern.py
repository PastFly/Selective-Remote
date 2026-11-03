#!/usr/bin/env python3
"""Make the pinned IronRDP example paint deterministic test-only color bars."""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('expected pinned IronRDP example path')
path = Path(sys.argv[1])
source = path.read_text()
start = '        let mut rng = rand::rng();\n'
end = '        let stride = NonZeroUsize::from(width)\n'
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit('pinned IronRDP display source changed')
begin = source.index(start)
finish = source.index(end, begin)
replacement = '''        let y = 0u16;
        let x = 0u16;
        let height = NonZeroU16::new(HEIGHT).expect("nonzero height");
        let width = NonZeroU16::new(WIDTH).expect("nonzero width");
        let mut data = Vec::with_capacity(usize::from(WIDTH) * usize::from(HEIGHT) * 4);
        for _ in 0..HEIGHT {
            for col in 0..WIDTH {
                let pixel = if col < WIDTH / 3 { [0, 0, 255, 255] }
                    else if col < 2 * WIDTH / 3 { [0, 255, 0, 255] }
                    else { [255, 0, 0, 255] };
                data.extend_from_slice(&pixel);
            }
        }
        info!("SYNTHETIC_RDP_PATTERN_UPDATE");
'''
path.write_text(source[:begin] + replacement + source[finish:])
