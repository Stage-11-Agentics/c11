import sys,json,time,os,struct
X=os.environ['X']
exec(open(X+'/hcx.py').read().split('cmd = sys.argv[1]')[0])
A=Conn(); ch=A.attach(sys.argv[1],cols=100,rows=30); drain(A,ch,0.5); print("attached to", sys.argv[1], flush=True)
t0=time.time()
while time.time()-t0<45:
    f=A.read_frame(2)
    if f and f[0]==ch and f[1]==CLOSE: print("  attach stream CLOSE after", round(time.time()-t0,1), "s:", f[2][:160], flush=True); break
    if f and f[0]==ch and f[1]==DATA: A.send_frame(ch, CREDIT, struct.pack("<I", len(f[2])))
else: print("  no CLOSE within 45 s", flush=True)
