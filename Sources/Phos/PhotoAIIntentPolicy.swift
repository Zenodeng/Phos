import Foundation

/// Explicit boundaries only. Open photographic directions retain the full tool vocabulary.
extension PhotoAIService {
    static func validateCapabilityRequest(_ instruction: String) throws {
        let clauses = instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n"))
        for clause in clauses {
            let text = clause.trimmingCharacters(in:.whitespacesAndNewlines)
            if ["不要","不需要","不使用","禁止","别用"].contains(where:text.hasPrefix) { continue }
            let patterns = ["生成式填充","生成式扩图","(?:替换|换成).{0,10}(?:天空|星空)","添加原图不存在","(?:移除|删除|去掉).{0,12}(?:路人|人物|物体).{0,12}(?:补齐|补全|填充)"]
            if patterns.contains(where:{text.range(of:$0,options:.regularExpression) != nil}) {
                throw PhotoAIError(message:"Phos 仅支持参数修图，不支持生成式填充、移除并重绘或添加物体。已保留原图与现有编辑，请改为描述光线、色彩或构图方向。")
            }
        }
    }
    static func exclusiveSlider(_ instruction: String) -> String? {
        let clauses = instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        for field in ParameterDescriptor.all where PhotoAIPlan.keys[field.id] != nil {
            let pattern = "(?:只把|仅把|只将|仅将)(?:全局|整体)?" + NSRegularExpression.escapedPattern(for:field.label) + "(?:设置为|设为|调到|调至)\\s*[-+]?\\d+(?:\\.\\d+)?(?:\\s*EV)?\\s*$"
            if let index = clauses.firstIndex(where:{$0.range(of:pattern,options:.regularExpression) != nil}), clauses.enumerated().allSatisfy({ i,c in
                i == index || c.contains("保持不变") || c.contains("保持原样") || c.contains("全部保持") || c.contains("不要新增蒙版") || c.contains("不加蒙版")
            }) { return field.id }
        }
        return nil
    }
    static func preservedAdvancedFields(_ instruction:String) -> [String:Set<String>] {
        let clauses=instruction.components(separatedBy:CharacterSet(charactersIn:"，,；;。\n"))
        let groups:[(String,String,[(String,String)])] = [
            ("curves","曲线",[("luma","亮度曲线"),("rgb","RGB曲线"),("red","红色曲线"),("green","绿色曲线"),("blue","蓝色曲线")]),
            ("hsl","HSL",zip(PhotoAIPlan.bands,["红色","橙色","黄色","绿色","青色","蓝色","紫色","洋红"]).map{($0.0,$0.1)}),
            ("grading","分级",[("shadows","阴影"),("midtones","中间调"),("highlights","高光")])]
        var locks=[String:Set<String>]()
        for c in clauses where c.contains("不变") || ["不改变","不调整","不要修改","别动","不要动","不使用","禁用"].contains(where:c.contains) {
            for (key,word,names) in groups where c.localizedCaseInsensitiveContains(word) {
                let selected=names.filter{c.localizedCaseInsensitiveContains($0.1)}.map{$0.0}
                locks[key,default:[]].formUnion(selected.isEmpty ? names.map{$0.0} : selected)
            }
        }
        return locks
    }
    static func scopedSchema(_ original:[String:Any], instruction:String) -> [String:Any] {
        var result=original, properties=original["properties"] as! [String:Any], required=original["required"] as! [String]
        var locked=preservedAdvancedFields(instruction)
        if let key=exclusiveSlider(instruction) {
            locked["curves"]=Set(PhotoAIPlan.curveKeys.keys);locked["hsl"]=Set(PhotoAIPlan.bands);locked["grading"]=Set(PhotoAIPlan.gradeKeys.keys)
            var globals=properties["adjustments"] as! [String:Any]
            let fields=globals["properties"] as! [String:Any];globals["properties"]=fields.filter{$0.key==key};properties["adjustments"]=globals
            var masks=properties["masks"] as! [String:Any];masks["maxItems"]=0;properties["masks"]=masks
        }
        for (key,names) in locked {
            guard var group=properties[key] as? [String:Any], var fields=group["properties"] as? [String:Any] else {continue}
            for name in names {fields.removeValue(forKey:name)}
            if fields.isEmpty {properties.removeValue(forKey:key);required.removeAll{$0==key}}
            else {group["properties"]=fields;if let r=group["required"] as? [String] {group["required"]=r.filter{!names.contains($0)}};properties[key]=group}
        }
        result["properties"]=properties;result["required"]=required;return result
    }
    static func validateIntentScope(_ plan:PhotoAIPlan, base:EditParams, instruction:String) throws {
        try validateCapabilityRequest(instruction)
        if let key=exclusiveSlider(instruction) {
            guard Set(plan.adjustments.keys).isSubset(of:[key]), plan.masks.isEmpty, (plan.curves ?? [:]).isEmpty, (plan.hsl ?? [:]).isEmpty, (plan.grading ?? [:]).isEmpty else {
                throw PhotoAIError(message:"本次明确只允许调整 \(key)，请删除曲线、HSL、分级、蒙版及其他调整。")
            }
        }
        let candidate=try plan.applying(to:base), locked=preservedAdvancedFields(instruction)
        for name in locked["curves"] ?? [] {if let path=PhotoAIPlan.curveKeys[name],candidate[keyPath:path] != base[keyPath:path] {throw PhotoAIError(message:"用户要求保持该曲线不变。")}}
        for name in locked["hsl"] ?? [] {if let i=PhotoAIPlan.bands.firstIndex(of:name),candidate.hsl[i] != base.hsl[i] {throw PhotoAIError(message:"用户要求保持该HSL分区不变。")}}
        for name in locked["grading"] ?? [] {if let path=PhotoAIPlan.gradeKeys[name],candidate[keyPath:path] != base[keyPath:path] {throw PhotoAIError(message:"用户要求保持该颜色分级不变。")}}
        if instruction.contains("不要新增蒙版"), !plan.masks.isEmpty {throw PhotoAIError(message:"用户要求不要新增蒙版。")}
    }
}
