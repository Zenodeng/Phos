import Foundation
import CoreImage

/// Radial, rectilinear Lensfun subset. Polynomial equations and coordinate conventions:
/// https://lensfun.github.io/manual/latest/group__Lens.html
/// No Lensfun program/library code is linked or copied.
enum LensProfileEngine {
    static func radial(_ r:Double,_ c:LensCalibration) -> Double {
        let k=c.coefficients
        return c.model == "poly5" ? 1+k[1]*r*r+k[0]*pow(r,4) : k[3]+k[2]*r+k[1]*r*r+k[0]*r*r*r
    }
    static func huginScale(_ c:LensCalibration,_ crop:Double) -> Double { c.crop/crop * sqrt(1+c.aspect*c.aspect) }
    static func mapping(_ p:CGPoint,aspect:Double,correction c:LensCorrection,scale:Double=1,channel:Int=1) -> CGPoint {
        var x=p.x/scale,y=p.y/scale
        if c.correctDistortion,let d=c.distortion { let r=hypot(x,y)*huginScale(d,c.cameraCrop), f=radial(r,d); x *= f; y *= f }
        if c.correctTCA,let t=c.tca,channel != 1 { let r=hypot(x,y)*huginScale(t,c.cameraCrop), i=channel==0 ? 0:3, k=t.coefficients; let f=k[i]*r*r+k[i+1]*r+k[i+2]; x *= f; y *= f }
        return CGPoint(x:x,y:y)
    }
    /// Sample the complete boundary, including corners and mid-edge bulges. Keep output dimensions.
    private static let cacheLock=NSLock()
    private static var cropCache:[(Double,LensCorrection,Double)]=[]
    static func cropScale(aspect:Double,correction c:LensCorrection) -> Double {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let value=cropCache.first(where:{$0.0==aspect && $0.1==c}) { return value.2 }
        let value=calculateCropScale(aspect:aspect,correction:c)
        cropCache.append((aspect,c,value)); if cropCache.count>16 { cropCache.removeFirst() }; return value
    }
    private static func calculateCropScale(aspect:Double,correction c:LensCorrection) -> Double {
        guard c.autoCrop else { return 1 }
        let halfX=aspect/sqrt(1+aspect*aspect),halfY=1/sqrt(1+aspect*aspect)
        func fits(_ scale:Double) -> Bool {
            for i in 0...256 {
                let t=Double(i)/128-1
                for point in [CGPoint(x:halfX*t,y:halfY),CGPoint(x:halfX*t,y:-halfY),CGPoint(x:halfX,y:halfY*t),CGPoint(x:-halfX,y:halfY*t)] {
                    for ch in 0...2 { let q=mapping(point,aspect:aspect,correction:c,scale:scale,channel:ch); if !q.x.isFinite || !q.y.isFinite || abs(q.x)>halfX*0.998 || abs(q.y)>halfY*0.998 { return false } }
                }
            }; return true
        }
        if fits(1) { return 1 }
        var lo=1.0,hi=4.0
        for _ in 0..<24 { let mid=(lo+hi)/2; if fits(mid) { hi=mid } else { lo=mid } }
        return hi
    }
    static let kernel:CIKernel? = CIKernel(source:"""
    float lensRadial(float r, vec4 k, float poly5) {
        return poly5 > 0.5 ? 1.0+k.y*r*r+k.x*r*r*r*r : k.w+k.z*r+k.y*r*r+k.x*r*r*r;
    }
    vec2 lensPoint(vec2 p, float hs, vec4 d, float poly5, vec3 t, float ts) {
        float f=lensRadial(length(p)*hs,d,poly5); p*=f;
        float r=length(p)*ts; return p*(t.x*r*r+t.y*r+t.z);
    }
    float lensGain(vec2 p, vec3 k, float vs) {
        float r2=dot(p,p)*vs*vs;
        return min(4.0,1.0/max(0.25,1.0+k.x*r2+k.y*r2*r2+k.z*r2*r2*r2));
    }
    kernel vec4 phosLens(sampler src, vec2 center, float radius, float zoom, vec4 d, float hs, float poly5, vec3 red, vec3 blue, float ts, vec3 vig, float vs) {
        vec2 p=(destCoord()-center)/radius/zoom;
        vec2 g=lensPoint(p,hs,d,poly5,vec3(0.0,0.0,1.0),ts);
        vec2 r=lensPoint(p,hs,d,poly5,red,ts);
        vec2 b=lensPoint(p,hs,d,poly5,blue,ts);
        vec4 sg=sample(src,samplerTransform(src,center+g*radius));
        vec4 sr=sample(src,samplerTransform(src,center+r*radius));
        vec4 sb=sample(src,samplerTransform(src,center+b*radius));
        return vec4(sr.r*lensGain(r,vig,vs),sg.g*lensGain(g,vig,vs),sb.b*lensGain(b,vig,vs),min(sg.a,min(sr.a,sb.a)));
    }
    """)
    static func apply(_ image:CIImage,_ value:LensCorrection?) -> CIImage {
        guard let c=value,c.enabled,c.valid,let kernel else { return image }
        let e=image.extent, aspect=max(e.width,e.height)/min(e.width,e.height)
        guard e.width>1,e.height>1,e.width.isFinite,e.height.isFinite else { return image }
        let d=c.correctDistortion ? c.distortion : nil,t=c.correctTCA ? c.tca:nil,v=c.correctVignetting ? c.vignetting:nil
        guard d != nil || t != nil || v != nil else { return image }
        let dk=d?.coefficients ?? [0,0,0,1],tk=t?.coefficients ?? [0,0,1,0,0,1],vk=v?.coefficients ?? [0,0,0,1]
        let zoom=cropScale(aspect:aspect,correction:c)
        return kernel.apply(extent:e,roiCallback:{_,_ in e},arguments:[image,CIVector(x:e.midX,y:e.midY),hypot(e.width,e.height)/2,zoom,CIVector(x:dk[0],y:dk[1],z:dk[2],w:dk[3]),d.map{huginScale($0,c.cameraCrop)} ?? 1,d?.model == "poly5" ? 1.0:0.0,CIVector(x:tk[0],y:tk[1],z:tk[2]),CIVector(x:tk[3],y:tk[4],z:tk[5]),t.map{huginScale($0,c.cameraCrop)} ?? 1,CIVector(x:vk[0],y:vk[1],z:vk[2]),v.map{$0.crop/c.cameraCrop} ?? 1]) ?? image
    }
}
