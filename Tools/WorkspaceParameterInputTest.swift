import Foundation

@main
struct WorkspaceParameterInputTest {
    static func main() {
        let range = -5.0...5.0
        for (draft,expected) in [("1,5",1.5),(" 0.125 ",0.13),("-0.125",-0.13),("50",5.0),("-50",-5.0),("1e308",5.0)] {
            precondition(ParameterInputPolicy.value(draft,in:range) == expected,draft)
        }
        for invalid in ["nan","inf","-inf","1.2,3","abc",""] {
            precondition(ParameterInputPolicy.value(invalid,in:range) == nil,invalid)
        }
        print("PASS: shared numeric policy accepts comma decimals, rounds, clamps, rejects nonfinite/invalid drafts")
    }
}
