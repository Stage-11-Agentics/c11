#!/usr/bin/env python3
import re,sys
for p in sys.argv[1:]:
    L=open(p).read().splitlines()
    def f(k): return [int(m.group(1)) for l in L for m in [re.search(k+r'=(\d+)',l)] if m]
    c,h,a=f('core_rss_kb'),f('hold_rss_kb'),f('app_rss_kb')
    print(f"{p.split('/')[-1]}: {len(L)} s; core MB start/max/end {c[0]//1024}/{max(c)//1024}/{c[-1]//1024}; holder {h[0]//1024}/{max(h)//1024}/{h[-1]//1024}; app {a[0]//1024}/{max(a)//1024}/{a[-1]//1024}")
