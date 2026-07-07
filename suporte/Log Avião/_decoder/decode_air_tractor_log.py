import struct, sys, math
from collections import Counter
sys.stdout.reconfigure(encoding='utf-8')
path = r"C:\Developer\Arquivos Suporte\Log Avião\07041204.log"
data = open(path,'rb').read(); n=len(data)

recs=[]; i=0
while i < n-43:
    if data[i]==0xA5 and data[i+1]==0x2B and data[i+2]==0x01:
        R=i
        lat=struct.unpack_from('<d',data,R+9)[0]; lon=struct.unpack_from('<d',data,R+17)[0]
        if -34<lat<6 and -74<lon<-32 and abs(lat)>1:
            recs.append(dict(
                tm=struct.unpack_from('<f',data,R+5)[0], lat=lat, lon=lon,
                alt=struct.unpack_from('<f',data,R+25)[0], spd=struct.unpack_from('<f',data,R+29)[0],
                hdg=struct.unpack_from('<f',data,R+33)[0], boom=data[R+42]))
            i=R+43; continue
    i+=1
print(f"registros: {len(recs)}")

def hav(a):  # a=((la1,lo1),(la2,lo2))
    R=6371000.0;(la1,lo1),(la2,lo2)=a;la1,lo1,la2,lo2=map(math.radians,[la1,lo1,la2,lo2])
    h=math.sin((la2-la1)/2)**2+math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(math.sqrt(h))

# flag boom por faixa de altitude
bands={}
for r in recs:
    key='<800' if r['alt']<800 else ('800-830' if r['alt']<830 else '>830')
    bands.setdefault(key,Counter())[r['boom']]+=1
print("boom por faixa de altitude:", {k:dict(v) for k,v in bands.items()})
on=[r for r in recs if r['boom']==2]; off=[r for r in recs if r['boom']!=2]
print(f"boom=2 (aplicando): {len(on)}  | boom!=2: {len(off)}")
print(f"  aplicando: alt média={sum(r['alt'] for r in on)/len(on):.0f} vel média={sum(r['spd'] for r in on)/len(on)*3.6:.0f} km/h")
print(f"  deslocando: alt média={sum(r['alt'] for r in off)/max(1,len(off)):.0f} vel média={sum(r['spd'] for r in off)/max(1,len(off))*3.6:.0f} km/h")

# comprimento aplicado (segmentos consecutivos com boom=2)
appl=0.0
for k in range(1,len(recs)):
    if recs[k]['boom']==2 and recs[k-1]['boom']==2:
        appl+=hav(((recs[k-1]['lat'],recs[k-1]['lon']),(recs[k]['lat'],recs[k]['lon'])))
total=sum(hav(((recs[k-1]['lat'],recs[k-1]['lon']),(recs[k]['lat'],recs[k]['lon']))) for k in range(1,len(recs)))
print(f"\ncomprimento total={total/1000:.1f} km | aplicado (boom on)={appl/1000:.1f} km")
for sw in (18,25,30):
    print(f"  área aplicada c/ faixa {sw} m ≈ {appl*sw/10000:.0f} ha")

# candidatos a largura de faixa (swath) no header: floats 'redondos' 5..50 nos primeiros 400 bytes
print("\nfloats redondos (5..50) no header (possível faixa/largura):")
seen=set()
for o in range(20,400):
    v=struct.unpack_from('<f',data,o)[0]
    if 5<=v<=50 and abs(v-round(v))<1e-3 and round(v) not in seen:
        print(f"  off={o}: {v:.1f}"); seen.add(round(v))
