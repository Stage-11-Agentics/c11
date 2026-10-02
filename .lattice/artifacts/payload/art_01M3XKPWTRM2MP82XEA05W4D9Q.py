import hashlib,json,os,pathlib,socket,subprocess,tempfile,time,uuid
SOCK='/tmp/c11-debug-c11-258-launch.sock'
ROOT=pathlib.Path(tempfile.mkdtemp(prefix='c11-258-runtime-',dir='/tmp'))
CLI=pathlib.Path.home()/'c11-builds/c11-258-launch/derived-test/Build/Products/Debug/c11'
def call(method,params={}):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(12);s.connect(SOCK)
        s.sendall((json.dumps({'id':str(uuid.uuid4()),'method':method,'params':params})+'\n').encode())
        raw=b''
        while b'\n' not in raw: raw+=s.recv(1048576)
    response=json.loads(raw);assert response['ok'],response
    return response['result']
def cli(*args):
    env=dict(os.environ,C11_SOCKET=SOCK,C11_SOCKET_PATH=SOCK)
    p=subprocess.run([str(CLI),'--socket',SOCK,'--json',*args],env=env,capture_output=True,text=True,timeout=15)
    assert p.returncode==0,p.stderr
    return json.loads(p.stdout)
fake=ROOT/'fake agent.py'
fake.write_text('''import hashlib,json,pathlib,sys,time
s=sys.argv[-1];pre="Read the file at ";suf=" and follow it exactly."
assert s.startswith(pre) and s.endswith(suf)
p=pathlib.Path(s[len(pre):-len(suf)])
time.sleep(2)
b=p.read_bytes()
pathlib.Path(sys.argv[1]).write_text(json.dumps({"bytes":len(b),"sha256":hashlib.sha256(b).hexdigest()}))
time.sleep(15)
''')
observations=[]
for kind in ['claude-code','codex']:
    receipt=ROOT/(kind+'.json')
    body="  synthetic ' \" $() `literal` 日本語\n"+'x'*32768+'\n trailing  '
    caller=ROOT/(kind+' original.txt');caller.write_bytes(body.encode())
    command='/usr/bin/python3 '+"'"+str(fake)+"' '"+str(receipt)+"'"
    before=cli('current-workspace')
    launched=call('agent.launch',{'type':kind,'command_override':command,'new_workspace':True,'prompt':body,'title':'C11-258 fixture','cwd':str(ROOT)})
    deadline=time.monotonic()+15
    while not receipt.exists() and time.monotonic()<deadline: time.sleep(.1)
    assert receipt.exists(),'fixture did not receive file instruction'
    result=json.loads(receipt.read_text());assert result['sha256']==hashlib.sha256(body.encode()).hexdigest()
    assert launched['startup']=='pending',launched['startup']
    assert body not in launched['command']
    owned=pathlib.Path(launched['prompt_file']);assert owned.read_bytes()==caller.read_bytes()
    assert cli('current-workspace')==before,'launch changed selected workspace'
    cli('close-workspace','--workspace',launched['workspace_id'])
    deadline=time.monotonic()+5
    while owned.exists() and time.monotonic()<deadline:time.sleep(.1)
    assert not owned.exists(),'owned file survived close'
    assert caller.read_bytes()==body.encode()
    observations.append({'kind':kind,'startup':launched['startup'],'bytes':result['bytes'],'sha256':result['sha256'],'close_cleanup':True,'caller_preserved':True,'focus_preserved':True})
(ROOT/'result.json').write_text(json.dumps(observations,indent=2))
print(json.dumps({'ok':True,'artifact':str(ROOT/'result.json'),'observations':observations}))
