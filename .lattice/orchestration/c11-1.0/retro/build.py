import os
d = os.path.dirname(os.path.abspath(__file__))
data = open(os.path.join(d, 'data', 'analysis.json')).read().replace('</', '<\\/')
html = open(os.path.join(d, 'template.html')).read().replace('__DATA__', data)
open(os.path.join(d, 'run-timeline.html'), 'w').write(html)
print('wrote run-timeline.html')
