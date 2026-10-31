import Foundation
import CoreImage
import ImageIO
import Combine

// Self-contained resolved calibration travels with the edit, including imported profiles.
struct LensCalibration: Codable, Equatable {
    var model: String
    var focal: Double
    var aperture: Double = 0
    var distance: Double = 0
    var crop: Double
    var aspect: Double = 1.5
    var coefficients: [Double]
}
struct LensCorrection: Codable, Equatable {
    var name: String
    var cameraCrop: Double
    var profileID: String? = nil
    var selectionMethod: String? = nil // Optional for backward-compatible saved edits.
    var captureFocal: Double? = nil
    var captureAperture: Double? = nil
    var captureDistance: Double? = nil
    var distortion: LensCalibration?
    var tca: LensCalibration?
    var vignetting: LensCalibration?
    var correctDistortion = true
    var correctTCA = true
    var correctVignetting = false
    var autoCrop = true
    var enabled = true
    var valid: Bool {
        guard distortion == nil || ["ptlens","poly5"].contains(distortion!.model),
              tca == nil || tca!.model == "tca", vignetting == nil || vignetting!.model == "pa" else { return false }
        guard cameraCrop.isFinite, (0.5...10.0).contains(cameraCrop) else { return false }
        for c in [distortion,tca,vignetting].compactMap({$0}) {
            guard c.crop.isFinite, (0.5...10.0).contains(c.crop), cameraCrop >= c.crop*0.98 else { return false }
            guard c.aspect.isFinite, (1.0...3.0).contains(c.aspect), c.focal.isFinite, c.focal > 0 else { return false }
            guard c.aperture.isFinite, c.distance.isFinite, c.coefficients.count == (c.model == "tca" ? 6 : 4) else { return false }
            guard c.coefficients.allSatisfy({$0.isFinite && abs($0)<=10}) else { return false }
            if c.model == "ptlens" || c.model == "poly5" {
                let k=c.coefficients, maxR=c.crop/cameraCrop*sqrt(1+c.aspect*c.aspect)
                for i in 0...64 {
                    let r=maxR*Double(i)/64
                    let f=c.model == "poly5" ? 1+k[1]*r*r+k[0]*pow(r,4) : k[3]+k[2]*r+k[1]*r*r+k[0]*r*r*r
                    let derivative=c.model == "poly5" ? 1+3*k[1]*r*r+5*k[0]*pow(r,4) : k[3]+2*k[2]*r+3*k[1]*r*r+4*k[0]*r*r*r
                    guard f>0.05, f<20, derivative>0.05 else { return false }
                }
            }

        }
        for number in [captureFocal,captureAperture,captureDistance].compactMap({$0}) { if !number.isFinite || number<0 { return false } }
        if let t=tca {
            let maxR=t.crop/cameraCrop*sqrt(1+t.aspect*t.aspect), k=t.coefficients
            for i in 0...64 { let r=maxR*Double(i)/64
                for j in [0,3] { let f=k[j]*r*r+k[j+1]*r+k[j+2]; if f<=0.05 || f>20 { return false } }
            }
        }
        return true
    }
}
struct LensProfile: Identifiable {
    var maker = "", name = "", crop = 1.0, aspect = 1.5, type = "rectilinear"
    var distortion: [LensCalibration] = [], tca: [LensCalibration] = [], vignetting: [LensCalibration] = []
    var id: String { maker + "|" + name + "|" + String(crop) }
    var title: String { name.lowercased().hasPrefix(maker.lowercased()) ? name : maker + " " + name }
    var supported: Bool { type == "rectilinear" && !name.localizedCaseInsensitiveContains("fisheye") && !(distortion.isEmpty && tca.isEmpty && vignetting.isEmpty) }
    func resolve(focal: Double, aperture: Double, distance: Double, cameraCrop: Double) -> LensCorrection? {
        guard supported, focal.isFinite, focal > 0, cameraCrop >= crop * 0.98 else { return nil }
        // Interpolate only between supported samples of the same model/calibration geometry.
        func atFocal(_ samples: [LensCalibration]) -> LensCalibration? {
            let ordered = samples.sorted { $0.focal < $1.focal }
            guard let first=ordered.first, let last=ordered.last, focal >= first.focal-0.05, focal <= last.focal+0.05 else { return nil }
            if let exact=ordered.first(where:{abs($0.focal-focal)<0.05}) { return exact }
            guard let lo=ordered.last(where:{$0.focal<focal}), let hi=ordered.first(where:{$0.focal>focal}), lo.model==hi.model, lo.crop==hi.crop, lo.aspect==hi.aspect else { return nil }
            var result=lo; let t=(focal-lo.focal)/(hi.focal-lo.focal); result.focal=focal
            result.coefficients=zip(lo.coefficients,hi.coefficients).map{$0+($1-$0)*t}; return result
        }
        // Vignetting is deliberately nearest measured sample, never extrapolated as a precise fit.
        let minimumVigFocal=vignetting.map(\.focal).min() ?? .infinity
        let maximumVigFocal=vignetting.map(\.focal).max() ?? 0
        let eligibleVignetting = focal >= minimumVigFocal-0.05 && focal <= maximumVigFocal+0.05 ? vignetting : []
        let vig = aperture > 0 && distance > 0 ? eligibleVignetting.min {
            abs(log($0.focal/focal))*4 + abs(log($0.aperture/aperture))*2 + abs(log(($0.distance+1)/(distance+1))) < abs(log($1.focal/focal))*4 + abs(log($1.aperture/aperture))*2 + abs(log(($1.distance+1)/(distance+1)))
        } : nil
        let result=LensCorrection(name:title,cameraCrop:cameraCrop,profileID:id,captureFocal:focal,captureAperture:aperture,captureDistance:distance,distortion:atFocal(distortion),tca:atFocal(tca),vignetting:vig)
        return result.valid && (result.distortion != nil || result.tca != nil || result.vignetting != nil) ? result : nil
    }
}

enum LensProfileError: LocalizedError {
    case invalid, unsupported, tooLarge
    var errorDescription: String? { L10n.tr(self == .tooLarge ? "配置文件过大（上限 8 MB）" : self == .unsupported ? "没有可用的直线镜头校正数据，请查看导入指引。" : "配置格式或系数无效，未导入任何数据。") }
}

// No external entities, DTD fetches, archives, scripts or arbitrary URL access during import.
final class LensXMLReader: NSObject, XMLParserDelegate {
    private var stack:[String]=[], text="", lens:LensProfile?, cameraName="", cameraCrop=0.0
    private var calibrationCrop:Double?, calibrationAspect:Double?
    private var localized=false, rejected=false
    private(set) var profiles:[LensProfile]=[], cameras:[String:Double]=[:]
    static func read(_ data:Data) throws -> LensXMLReader {
        guard data.count <= 8*1024*1024 else { throw LensProfileError.tooLarge }
        guard let xml=String(data:data,encoding:.utf8), !xml.uppercased().contains("<!ENTITY") else { throw LensProfileError.invalid }
        let withoutKnownDTD=xml.replacingOccurrences(of:"<!DOCTYPE lensdatabase SYSTEM \"lensfun-database.dtd\">",with:"")
        guard !withoutKnownDTD.uppercased().contains("<!DOCTYPE") else { throw LensProfileError.invalid }
        let reader=LensXMLReader(), parser=XMLParser(data:Data(withoutKnownDTD.utf8)); parser.shouldResolveExternalEntities=false; parser.delegate=reader
        guard parser.parse(), !reader.rejected, reader.stack.isEmpty else { throw LensProfileError.invalid }
        reader.profiles=reader.profiles.filter(\.supported)
        guard !reader.profiles.isEmpty else { throw LensProfileError.unsupported }; return reader
    }
    func parser(_ parser:XMLParser,didStartElement e:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        stack.append(e); text=""
        if stack.count>16 || profiles.count>5000 { rejected=true; parser.abortParsing(); return }
        if stack.count==1 && (e != "lensdatabase" || !["1","2"].contains(a["version"] ?? "1")) { rejected=true; parser.abortParsing(); return }
        if e=="lens" { lens=LensProfile() }
        if e=="camera" { cameraName=""; cameraCrop=0 }
        if e=="model" || e=="maker" { localized=a["lang"] != nil }
        if e=="calibration" { calibrationCrop=Double(a["cropfactor"] ?? ""); calibrationAspect=Double(a["aspect-ratio"] ?? "") }
        guard let l=lens, l.type == "rectilinear", ["distortion","tca","vignetting"].contains(e) else { return }
        func number(_ key:String,_ fallback:Double=0) -> Double { a[key].flatMap(Double.init) ?? (a[key] == nil ? fallback : .nan) }
        let model=a["model"] ?? "", crop=calibrationCrop ?? l.crop, aspect=calibrationAspect ?? l.aspect
        let focal=number("focal"), aperture=number("aperture"), distance=number("distance")
        var coefficients:[Double]=[], canonical=""
        if e=="distortion" {
            switch model {
            case "poly3": let k=number("k1"); coefficients=[0,k,0,1-k]
            case "poly5": coefficients=[number("k2"),number("k1"),0,1]; canonical="poly5"
            case "ptlens": let x=number("a"), y=number("b"), z=number("c"); coefficients=[x,y,z,1-x-y-z]
            default: return
            }
            if canonical.isEmpty { canonical="ptlens" }
        } else if e=="tca" {
            if model=="linear" { coefficients=[0,0,number("kr",1),0,0,number("kb",1)] }
            else if model=="poly3" { coefficients=[number("br"),number("cr"),number("vr",1),number("bb"),number("cb"),number("vb",1)] }
            else { return }; canonical="tca"
        } else {
            guard model=="pa", aperture>0, aperture.isFinite, distance>0, distance.isFinite else { return }
            canonical="pa"; coefficients=[number("k1"),number("k2"),number("k3"),1]
        }
        guard focal.isFinite, focal>0, focal<=3000, (0.5...10).contains(crop), (1...3).contains(aspect), coefficients.allSatisfy({$0.isFinite && abs($0)<=10}) else { rejected=true; parser.abortParsing(); return }
        let sample=LensCalibration(model:canonical,focal:focal,aperture:aperture,distance:distance,crop:crop,aspect:aspect,coefficients:coefficients)
        if e=="distortion" { lens?.distortion.append(sample) }; if e=="tca" { lens?.tca.append(sample) }; if e=="vignetting" { lens?.vignetting.append(sample) }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { text+=string; if text.count>4096 { rejected=true; parser.abortParsing() } }
    func parser(_ parser:XMLParser,didEndElement e:String,namespaceURI:String?,qualifiedName:String?) {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if stack.dropLast().last=="lens" {
            if e=="maker" && !localized { lens?.maker=value }; if e=="model" && !localized { lens?.name=value }
            if e=="cropfactor" { lens?.crop=Double(value) ?? 0 }; if e=="aspect-ratio" { lens?.aspect=Double(value) ?? 0 }
            if e=="type" { lens?.type=value }
            if e=="center" { lens?.type="unsupported-center" }
        }
        if stack.dropLast().last=="camera" { if e=="model" && !localized { cameraName=value }; if e=="cropfactor" { cameraCrop=Double(value) ?? 0 } }
        if e=="camera", !cameraName.isEmpty, cameraCrop>0 { cameras[cameraName]=cameraCrop }
        if e=="calibration" { calibrationCrop=nil; calibrationAspect=nil }
        if e=="lens" { if let l=lens,!l.name.isEmpty,!l.maker.isEmpty { profiles.append(l) }; lens=nil }
        stack.removeLast(); text=""
    }
}

@MainActor
final class LensProfileStore: ObservableObject {
    static let shared=LensProfileStore()
    @Published private(set) var profiles:[LensProfile]=[]
    private(set) var cameras:[String:Double]=[:]
    let directory:URL
    private let bundledURL:URL?
    init(directory:URL?=nil,bundledURL:URL?=nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Phos/LensProfiles",isDirectory:true)
        self.bundledURL=bundledURL ?? Bundle.main.resourceURL?.appendingPathComponent("LensProfiles/bundled.xml")
        reload()
    }
    func reload() {
        var all:[String:LensProfile]=[:]; cameras=[:]
        let bundled=bundledURL
        let local=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        for url in ([bundled].compactMap{$0}+local.filter{$0.pathExtension.lowercased()=="xml"}.sorted {
            let a=(try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b=(try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }) {
            guard let data=try? Data(contentsOf:url),let db=try? LensXMLReader.read(data) else { continue }
            for p in db.profiles { all[p.id]=p }; cameras.merge(db.cameras){_,n in n}
        }
        profiles=all.values.sorted{$0.title.localizedStandardCompare($1.title) == .orderedAscending}
    }
    func importFile(_ url:URL) throws -> Int {
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size<=8*1024*1024 else { throw LensProfileError.tooLarge }
        let data=try Data(contentsOf:url), db=try LensXMLReader.read(data)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        // Unique destination preserves earlier imports and the selected source file.
        try data.write(to:directory.appendingPathComponent(UUID().uuidString+".xml"),options:.atomic)
        reload(); return db.profiles.count
    }
    static func normalized(_ name:String) -> String {
        let base=name.lowercased().components(separatedBy:"|")[0]
        return base.replacingOccurrences(of:"canon",with:"").replacingOccurrences(of:"sigma",with:"").filter{$0.isLetter || $0.isNumber}
    }
    func matches(_ name:String) -> [LensProfile] { guard !name.isEmpty else { return [] }; return profiles.filter{Self.normalized($0.name)==Self.normalized(name)} }
}

struct LensPhotoMetadata {
    var lens="", camera="", focal=0.0, aperture=0.0, crop:Double?
    init(url:URL?) {
        guard let url,let src=CGImageSourceCreateWithURL(url as CFURL,nil),let meta=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] else { return }
        let exif=meta[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:], tiff=meta[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        lens=exif[kCGImagePropertyExifLensModel as String] as? String ?? ""; camera=tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        focal=(exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0
        aperture=(exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0
    }
}
