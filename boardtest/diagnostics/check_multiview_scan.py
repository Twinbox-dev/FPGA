#!/usr/bin/env python3
"""Real display scan acceptance for the isolated --test-cursor build.

The probe bypasses CV only to fit its temporary hardware; it samples the actual
SDRAM video returns before CV. Product GT911, CV, and bit files are unmodified.
Current-card FAT indices below were verified by stage-one real D captures.
"""
from __future__ import annotations
import argparse
from array import array
import functools
import json
from pathlib import Path
import queue
import re
import socket
import struct
import sys
import threading
import time
import urllib.request

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pc_display_media_probe import bmp_native_words

ORDER=(1,3,5,6,7,9)
NAMES={1:'IMG1.BMP',3:'IMG2.BMP',5:'IMG3.BMP',6:'IMG4.BMP',7:'IMG5.BMP',9:'IMG0.BMP'}
PAIRED={1,3,7,9}


def step_index(index,delta=1):
    return ORDER[(ORDER.index(index)+delta)%len(ORDER)]


@functools.lru_cache(maxsize=18)
def slot_golden(index,layout):
    words,sw,sh=bmp_native_words(ROOT/'img/golden'/NAMES[index])
    source=array('H')
    for word in words:source.extend((word&65535,word>>16))
    cw,ch=(1280,720) if layout==0 else ((640,720) if layout==1 else (640,360))
    dw,dh=sw,sh
    if sw>cw or sh>ch:
        if sw*ch>=sh*cw:dw,dh=cw,max(1,sh*cw//sw)
        else:dw,dh=max(1,sw*ch//sh),ch
    left,bottom=(cw-dw)//2,(ch-dh+1)//2
    output=array('I',[0])*(cw*ch//2)
    for y in range(dh):
        yq=((sh-1)<<15) if dh==1 else (((sh-1)<<16) if y==dh-1 else (((sh-1)<<16)//(dh-1))*y)
        y0=yq>>16;y1=min(y0+1,sh-1);fy=(yq>>8)&255
        for x in range(dw):
            if dw==sw and dh==sh:pixel=source[y*sw+x]
            else:
                xq=((sw-1)<<15) if dw==1 else (((sw-1)<<16) if x==dw-1 else (((sw-1)<<16)//(dw-1))*x)
                x0=xq>>16;x1=min(x0+1,sw-1);fx=(xq>>8)&255
                a,b=source[y0*sw+x0],source[y0*sw+x1]
                c,d=source[y1*sw+x0],source[y1*sw+x1]
                pixel=0
                for shift,mask in ((11,31),(5,63),(0,31)):
                    va,vb,vc,vd=((v>>shift)&mask for v in (a,b,c,d))
                    value=(va*(256-fx)*(256-fy)+vb*fx*(256-fy)+
                           vc*(256-fx)*fy+vd*fx*fy+32768)>>16
                    pixel|=value<<shift
            p=(bottom+y)*cw+left+x
            output[p>>1]|=pixel<<(16*(p&1))
    # Per-slot SDRAM writes vertically flip the bottom-up producer stream.
    top=array('I')
    for y in range(ch-1,-1,-1):top.extend(output[y*(cw//2):(y+1)*(cw//2)])
    return top


def scan_golden(layout,indices):
    slots=[slot_golden(index,layout) for index in indices]
    output=array('I')
    if layout==0:output=slots[0]
    else:
        for y in range(720):
            first=0 if layout==1 or y<360 else 2
            local_y=y if layout==1 else y%360
            for window in (first,first+1):output.extend(slots[window][local_y*320:(local_y+1)*320])
    ordered=0
    for word in output:ordered=((ordered*33)^word)&0xffffffff
    return len(output),sum(output)&0xffffffff,ordered


class Acceptance:
    def __init__(self,url,output):
        self.url=url;self.output=output;self.records=[];self.events=queue.Queue()
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.sock.bind(('192.168.137.1',4));self.sock.settimeout(.3)
        def events():
            try:
                with urllib.request.urlopen(url+'/api/stream',timeout=3600) as stream:
                    for line in stream:
                        if line.startswith(b'data: '):self.events.put(json.loads(line[6:]))
            except Exception:pass
        threading.Thread(target=events,daemon=True).start()

    def http(self,path,payload=None,head=False):
        req=urllib.request.Request(self.url+path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={} if payload is None else {'Content-Type':'application/json'},
            method='HEAD' if head else ('GET' if payload is None else 'POST'))
        with urllib.request.urlopen(req,timeout=15) as response:return response.headers,response.read()

    def command(self,key):
        _,data=self.http('/api/cmd',{'mode':'eth','key':key})
        if not json.loads(data).get('ok'):raise RuntimeError(data)

    def raw(self,key):
        self.sock.sendto(bytes.fromhex('aa bb cc dd 00 01 00 02')+bytes((ord(key),ord(key)^255)),('192.168.137.3',1))

    def view(self):
        return json.loads(self.http('/api/status')[1]).get('view')

    def wait(self,predicate,timeout=30):
        end=time.monotonic()+timeout;last=None;query=0
        while time.monotonic()<end:
            last=self.view()
            if last is not None and predicate(last):return last
            if time.monotonic()>=query:self.command('s');query=time.monotonic()+.5
            time.sleep(.06)
        raise TimeoutError(f'view timeout: {last}')

    def idle(self):return self.wait(lambda v:not v['busy'] and v['valid_mask']!=0)

    def focus(self,window):
        current=self.idle();mode=current['layout']
        x=960 if window&1 else 320;y=540 if mode==2 and window>=2 else 180
        self.sock.sendto(bytes.fromhex('aa bb cc dd 00 4b 00 04')+struct.pack('<HH',x,y),('192.168.137.2',1))
        self.command('s')
        return self.wait(lambda v:not v['busy'] and v['focus']==window)

    def capture(self,label,layout,indices):
        expected=scan_golden(layout,tuple(indices));last=None
        end=time.monotonic()+6
        while time.monotonic()<end:
            self.sock.sendto(bytes.fromhex('aa bb cc dd 00 47 00 00'),('192.168.137.2',1))
            try:data,_=self.sock.recvfrom(2048)
            except socket.timeout:continue
            if len(data)!=72 or data[:8]!=bytes.fromhex('aa bb cc dd 00 47 00 40'):continue
            frame,magic,bank,count,total,ordered=struct.unpack('<HBBIII',data[8:24])
            last=(count,total,ordered)
            if magic==0xd9 and last==expected:
                record={'label':label,'layout':layout,'indices':indices,'scan_frame':frame,'bank':bank,
                        'words':count,'sum':f'{total:08x}','ordered_hash':f'{ordered:08x}'}
                self.records.append(record);self.save();print('PASS',json.dumps(record),flush=True);return
        raise ValueError(f'{label}: actual display scan {last}, expected {expected}')

    def snapshot(self,index):
        old=self.http('/api/frame?slot=snapshot',head=True)[0]['X-Frame-Id']
        self.command('d');end=time.monotonic()+20
        while time.monotonic()<end:
            header,_=self.http('/api/frame?slot=snapshot',head=True)
            if header['X-Frame-Id']!=old:
                header,raw=self.http('/api/frame?slot=snapshot');break
            time.sleep(.1)
        else:raise TimeoutError('D source snapshot')
        words,w,h=bmp_native_words(ROOT/'img/golden'/NAMES[index])
        if (int(header['X-Frame-Width']),int(header['X-Frame-Height']),int(header['X-Frame-Gaps']))!=(w,h,0) or raw!=array('I',words).tobytes():
            raise ValueError(f'D source differs from focused image {index}')
        self.command('s');self.idle();print(f'PASS D focused source {index} {w}x{h}',flush=True)

    def audio_status(self,index,layout):
        while not self.events.empty():self.events.get_nowait()
        self.command('s');end=time.monotonic()+3
        while time.monotonic()<end:
            try:event=self.events.get(timeout=.2)
            except queue.Empty:continue
            text=event.get('text','')
            if event.get('kind')=='status' and re.search(rf'img={index}(?:\+wav)?\b',text):
                paired=bool(re.search(r'img=\d+\+wav\b',text))
                if paired!=(layout==0 and index in PAIRED):raise ValueError(f'paired audio state: {text}')
                return
        raise TimeoutError('audio state A5')

    def save(self,error=None):
        self.output.parent.mkdir(parents=True,exist_ok=True)
        self.output.write_text(json.dumps({'scope':'isolated actual SDRAM scan; CV bypassed; injected cursor',
                                          'results':self.records,'error':error},indent=2),encoding='utf-8')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',default='http://127.0.0.1:5000')
    parser.add_argument('--output',type=Path,default=ROOT/'boardtest/captures/multiview_acceptance.json')
    args=parser.parse_args();test=Acceptance(args.url,args.output)
    try:
        state=test.idle()
        if state['layout']!=0:raise ValueError('start from freshly configured single-image mode')
        layout=0;indices=[state['indices'][0]];generation=state['generation']
        test.capture('initial single',layout,indices);test.audio_status(indices[0],0)

        def change(key,mode,expected,inject_busy=False):
            nonlocal layout,indices,generation
            before=test.idle();target_generation=generation+(mode!=layout)
            test.command(key)
            if inject_busy:
                test.wait(lambda v:v['busy'])
                for raw in ('n','p','d','8'):test.raw(raw);time.sleep(.003)
            result=test.wait(lambda v:not v['busy'] and v['generation']==target_generation and
                v['layout']==mode and v['indices'][:len(expected)]==expected and v['sequence']!=before['sequence'])
            if result['valid_mask']!=(1<<len(expected))-1:raise ValueError('incomplete visible-page mask')
            layout,indices,generation=mode,expected,target_generation
            test.capture(f'command {key} focus {result["focus"]}',layout,indices)

        change('7',1,[indices[0],step_index(indices[0])],True)
        for window in (0,1):
            test.focus(window)
            for key,delta in (('n',1),('p',-1)):
                expected=indices.copy();expected[window]=step_index(expected[window],delta)
                change(key,layout,expected)
            test.snapshot(indices[window]);test.capture(f'D leaves window {window} unchanged',layout,indices)
        test.audio_status(indices[1],layout)
        test.focus(1);change('6',0,[indices[1]]);test.audio_status(indices[0],0)
        page=[indices[0]]
        for _ in range(3):page.append(step_index(page[-1]))
        change('8',2,page)
        for window in range(4):
            test.focus(window)
            expected=indices.copy();expected[window]=step_index(expected[window])
            change('n',layout,expected)
            test.snapshot(indices[window])
        test.focus(3)
        # Explicitly cross the last->first boundary in one persistent window.
        while indices[3]!=ORDER[0]:
            expected=indices.copy();expected[3]=step_index(expected[3]);change('n',2,expected)
        previous=indices.copy();test.raw('7');test.command('s')
        test.wait(lambda v:not v['busy'] and v['layout']==2 and v['result']==2)
        test.capture('FPGA rejects quad-to-dual bypass command',2,previous)
        test.focus(0);change('6',0,[indices[0]]);test.audio_status(indices[0],0)
        print('PASS: real SDRAM multiview, source D, independent slots, wrap and invalid/busy admission',flush=True)
    except Exception as error:
        test.save(repr(error));raise
    finally:test.sock.close()


if __name__=='__main__':main()
