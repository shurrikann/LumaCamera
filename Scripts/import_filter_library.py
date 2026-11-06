#!/usr/bin/env python3
# coding: utf-8
"""Build app colour tables from 512px tiled PNGs and Resolve 3D CUBE files.
Input RGB is display-referred sRGB unless the author supplies a separate profile.
PNG tables are stored as RGBA8 and expanded lazily; CUBE Float32 values remain unclipped.
"""
import argparse,array,hashlib,json,math,shlex,sys,unicodedata,re
from pathlib import Path
from PIL import Image

def convert(source,root):
    entries=[]
    files=sorted((p for p in source.iterdir() if p.suffix.lower() in ('.png','.cube')),key=lambda p:unicodedata.normalize('NFC',p.name))
    for path in files:
        name=unicodedata.normalize('NFC',path.stem)
        style={'徕卡M9':'leicaM9','富士 NC':'fujiNC','富士CC':'fujiCC'}.get(name,'lut'+hashlib.sha256(unicodedata.normalize('NFC',path.name).encode()).hexdigest()[:10])
        asset='FilmLUT-M9' if style=='leicaM9' else 'ImportedLUT-'+style
        equipment=next((x for x in ['富士','徕卡','柯达','哈苏','理光','ARRI'] if name.startswith(x)),None)
        button=name[len(equipment):].strip() if equipment else name
        if path.suffix.lower()=='.png':
            im=Image.open(path).convert('RGBA')
            if im.size!=(512,512) or im.getchannel('A').getextrema()!=(255,255):raise ValueError('Expected opaque 512px tiled LUT: '+path.name)
            dimension=64; storage='rgba8'; data=bytearray()
            pixels=im.load()
            for b in range(64):
                for g in range(64):
                    for red in range(64):data.extend(pixels[(b%8)*64+red,(b//8)*64+g])
            data=bytes(data)
        else:
            dimension=None;values=[];domainMin=[0,0,0];domainMax=[1,1,1]
            for line in path.read_text(encoding='utf-8-sig').splitlines():
                tokens=shlex.split(line,comments=True)
                if not tokens:continue
                if tokens[0]=='TITLE':continue
                if tokens[0]=='LUT_3D_SIZE':dimension=int(tokens[1]);continue
                if tokens[0]=='DOMAIN_MIN':domainMin=list(map(float,tokens[1:]));continue
                if tokens[0]=='DOMAIN_MAX':domainMax=list(map(float,tokens[1:]));continue
                if tokens[0].startswith('LUT_'):raise ValueError('Unsupported 1D/shaper LUT: '+path.name)
                rgb=list(map(float,tokens))
                if len(rgb)!=3 or not all(math.isfinite(v) for v in rgb):raise ValueError('Invalid CUBE row')
                values.extend(rgb+[1.0])
            if dimension is None or not 2<=dimension<=64 or len(values)!=dimension**3*4:raise ValueError('CUBE size mismatch: '+path.name)
            if domainMin!=[0,0,0] or domainMax!=[1,1,1]:raise ValueError('Non-default CUBE domain requires explicit encoded-space normalization')
            floats=array.array('f',values)
            if sys.byteorder!='little':floats.byteswap()
            data=floats.tobytes();storage='rgba32f'
        if style!='leicaM9':
            folder=root/'LumaCamera/Resources/Assets.xcassets'/(asset+'.dataset');folder.mkdir(parents=True,exist_ok=True)
            filename='table.'+storage;(folder/filename).write_bytes(data)
            (folder/'Contents.json').write_text(json.dumps({'data':[{'filename':filename,'idiom':'universal'}],'info':{'author':'xcode','version':1}},indent=2)+'\n')
        else:storage='rgba32f'
        entries.append(dict(style=style,title=(equipment+' '+button if equipment else name),equipment=equipment,button=button,asset=asset,dimension=dimension,storage=storage,source=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),inputColorSpace='sRGB (display-referred assumption; source has no explicit profile)'))
    entries.sort(key=lambda e:({'leicaM9':0,'fujiNC':1,'fujiCC':2}.get(e['style'],3),e['title']))
    (root/'Docs/Imported-Filter-Manifest.json').write_text(json.dumps(entries,ensure_ascii=False,indent=2)+'\n')
    cases=[e['style'] for e in entries if e['style'] not in ['leicaM9','fujiNC','fujiCC']]
    p=root/'LumaCamera/Core/Imaging/FilmStyle.swift';s=p.read_text();s=re.sub(r'\n    case lut[^\n]+', '', s);s=s.replace('case original, daylight, amber, cinema, leicaM9, fujiNC, fujiCC, mono','case original, daylight, amber, cinema, leicaM9, fujiNC, fujiCC, mono\n    case '+', '.join(cases))
    if 'ImportedFilterCatalog.entries.map' not in s:
        s=s.replace('static let availableStyles: [FilmStyle] = [.original, .leicaM9]','static let availableStyles: [FilmStyle] = [.original] + ImportedFilterCatalog.entries.map(\\.style)')
        s=s.replace('        case .mono: return "银盐"','        case .mono: return "银盐"\n        default: return ImportedFilterCatalog.definition(for: self)?.title ?? rawValue',1)
        s=s.replace('''        switch self { case .leicaM9: return "徕卡"; case .fujiNC, .fujiCC: return "富士"; default: return nil }''','''        ImportedFilterCatalog.definition(for: self)?.equipment''',1)
        s=s.replace('''        switch self { case .leicaM9: return "M9"; case .fujiNC: return "NC"; case .fujiCC: return "CC"; default: return title }''','''        ImportedFilterCatalog.definition(for: self)?.buttonName ?? title''',1)
        s=s.replace('        case .mono: return "SILVER & SHADOW"','        case .mono: return "SILVER & SHADOW"\n        default: return "REFERENCE LUT"',1)
        s=s.replace('''        switch self {
            case .original: output = input''','''        if let reference = ImportedFilterCatalog.definition(for: self) {
                output = ImportedFilterCatalog.apply(reference, to: input)
            } else { switch self {
            case .original: output = input''',1)
        s=s.replace('''            output = input.applyingFilter("CIPhotoEffectNoir")
            }''','''            output = input.applyingFilter("CIPhotoEffectNoir")
            default: output = input
            } }''',1)
    p.write_text(s)
    def swift(s):return json.dumps(s,ensure_ascii=False)
    lines=[]
    for e in entries:
        equipment=swift(e['equipment']) if e['equipment'] else 'nil'
        lines.append(f'        .init(style: .{e["style"]}, title: {swift(e["title"])}, equipment: {equipment}, buttonName: {swift(e["button"])}, asset: {swift(e["asset"])}, dimension: {e["dimension"]}, compact: {str(e["storage"]=="rgba8").lower()}),')
    (root/'LumaCamera/Core/Imaging/ImportedFilterCatalog.swift').write_text('''import CoreImage
import UIKit
import Accelerate

struct ImportedFilterDefinition {
    let style: FilmStyle
    let title: String
    let equipment: String?
    let buttonName: String
    let asset: String
    let dimension: Int
    let compact: Bool
}

/// Bounded, thread-safe cache; importing many filters must not retain every 64³ Float32 cube.
enum ImportedFilterCatalog {
    static let entries: [ImportedFilterDefinition] = [
'''+ '\n'.join(lines)+'''
    ]
    private static let definitions = Dictionary(uniqueKeysWithValues: entries.map { ($0.style, $0) })
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 4; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    static func definition(for style: FilmStyle) -> ImportedFilterDefinition? { definitions[style] }
    static func table(_ definition: ImportedFilterDefinition) -> FilmColorLUT? {
        if definition.style == .leicaM9 { return FilmColorLUT.m9 }
        if let cached = cache.object(forKey: definition.asset as NSString) {
            return FilmColorLUT(dimension: definition.dimension, bytes: cached as Data)
        }
        guard let source = NSDataAsset(name: definition.asset)?.data else { return nil }
        let count = definition.dimension * definition.dimension * definition.dimension * 4
        let data: Data
        if definition.compact {
            guard source.count == count else { return nil }
            var floats = [Float](repeating: 0, count: count)
            source.withUnsafeBytes { bytes in
                floats.withUnsafeMutableBufferPointer { output in
                    vDSP_vfltu8(bytes.bindMemory(to: UInt8.self).baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(count))
                    var divisor: Float = 255
                    vDSP_vsdiv(output.baseAddress!, 1, &divisor, output.baseAddress!, 1, vDSP_Length(count))
                }
            }
            data = floats.withUnsafeBytes { Data($0) }
        } else {
            guard source.count == count * MemoryLayout<Float>.size else { return nil }
            data = source
        }
        cache.setObject(data as NSData, forKey: definition.asset as NSString, cost: data.count)
        return FilmColorLUT(dimension: definition.dimension, bytes: data)
    }
    static func apply(_ definition: ImportedFilterDefinition, to image: CIImage) -> CIImage {
        table(definition)?.apply(to: image) ?? image
    }
}
''')
    print(f'Imported {len(entries)} filters ({sum(e["storage"]=="rgba8" for e in entries)} compact PNG tables)')

if __name__=='__main__':
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('source',type=Path);a.add_argument('project',type=Path);args=a.parse_args();convert(args.source,args.project)
