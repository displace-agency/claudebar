import Foundation

struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    func cost(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) -> Double {
        let m = 1_000_000.0
        return (Double(input) * self.input
              + Double(output) * self.output
              + Double(cacheCreation) * self.cacheWrite
              + Double(cacheRead) * self.cacheRead) / m
    }
}

enum Pricing {
    static func price(for model: String) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("opus") {
            return ModelPricing(input: 15.00, output: 75.00, cacheWrite: 18.75, cacheRead: 1.50)
        }
        if m.contains("sonnet") {
            return ModelPricing(input: 3.00, output: 15.00, cacheWrite: 3.75, cacheRead: 0.30)
        }
        if m.contains("haiku") {
            return ModelPricing(input: 1.00, output: 5.00, cacheWrite: 1.25, cacheRead: 0.10)
        }
        return ModelPricing(input: 3.00, output: 15.00, cacheWrite: 3.75, cacheRead: 0.30)
    }

    static func family(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        return model
    }
}
