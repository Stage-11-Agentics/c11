import sys,json,time,os
X=os.environ['X']
exec(open(X+'/hcx.py').read().split('cmd = sys.argv[1]')[0])
c=Conn(framed=False)
env={k:"" for k in ["C11_PANEL_ID","C11_WORKSPACE_ID","C11_SOCKET_PATH","C11_PANEL_NUM","C11_SHELL_INTEGRATION","CMUX_SURFACE_ID","CMUX_SOCKET_PATH","CMUX_WORKSPACE_ID","C11_AGENT_TYPE","C11_AGENT_MODEL","C11_AGENT_TASK","CLAUDECODE","CLAUDE_CODE_ENTRYPOINT"]}
env["TERM"]="xterm-256color"
r=c.call_plain('terminal.run',{'argv':[os.path.expanduser('~/.local/share/claude/versions/2.1.314')],'name':'cc','no_parent':True,'cwd':X+'/claude-cwd','env':env})
print('run:', json.dumps(r.get('result',r.get('error')))[:200])
for i in range(12):
    time.sleep(1.5)
    t=c.call_plain('terminal.get',{'terminal':'cc'})['result']
    print(f"  t+{(i+1)*1.5:.1f}s reported={t.get('reported')} status={t.get('status')} turn={t.get('turn')} title={t.get('title')!r} fg={(t.get('foreground') or {}).get('name')}")
    if t.get('reported') and i>=3: break
rd=c.call_plain('terminal.read',{'terminal':'cc','lines':0})['result']['text']
print('--- screen (last 12 lines) ---'); print('\n'.join(rd.splitlines()[-12:]))
c.call_plain('terminal.kill',{'terminal':'cc'}); time.sleep(1)
