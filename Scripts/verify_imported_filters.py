from pathlib import Path
import json, numpy as np, hashlib, shlex, argparse
from PIL import Image
parser=argparse.ArgumentParser(description='Verify every imported LUT grid point against source PNG/CUBE; requires Pillow and numpy.')
parser.add_argument('source',type=Path)
parser.add_argument('--project',type=Path,default=Path(__file__).resolve().parent.parent)
parser.add_argument('--output',type=Path)
args=parser.parse_args();root=args.project;source=args.source
rows=[]
for e in json.loads((root/'Docs/Imported-Filter-Manifest.json').read_text()):
 p=source/e['source']; n=e['dimension']; folder=root/'LumaCamera/Resources/Assets.xcassets'/(e['asset']+'.dataset')
 info=json.loads((folder/'Contents.json').read_text()); data=(folder/info['data'][0]['filename']).read_bytes()
 stored=np.frombuffer(data,np.uint8 if e['storage']=='rgba8' else '<f4').reshape(n,n,n,4).astype(float)
 if e['storage']=='rgba8': stored/=255
 if p.suffix=='.png':
  im=Image.open(p).convert('RGBA'); a=np.asarray(im)/255
  expected=np.stack([a[(b//8)*64:(b//8+1)*64,(b%8)*64:(b%8+1)*64] for b in range(64)])
 else:
  values=[]
  for line in p.read_text(encoding='utf-8-sig').splitlines():
   t=shlex.split(line,comments=True)
   if not t or t[0] in ['TITLE','LUT_3D_SIZE','DOMAIN_MIN','DOMAIN_MAX']:continue
   values.append(list(map(float,t))+[1])
  expected=np.asarray(values).reshape(n,n,n,4)
 err=float(np.max(np.abs(stored-expected)))
 assert err<0.000001,(e['title'],err)
 assert np.isfinite(stored).all()
 rows.append(dict(style=e['style'],title=e['title'],gridPoints=n**3,maxError=err,sourceHashMatches=hashlib.sha256(p.read_bytes()).hexdigest()==e['sha256']))
if args.output: args.output.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print('Verified',len(rows),'tables;',sum(r['gridPoints'] for r in rows),'grid points; max component error',max(r['maxError'] for r in rows))
