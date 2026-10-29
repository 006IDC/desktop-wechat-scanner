import Foundation

/// Matching only, after OCR: never supplies expected text to the recognizer.
enum SyntheticResultText {
    static func matches(_ words:[ScannerNavigationOCR.Text],expected:String)->Bool {
        let token="(?<![A-Za-z0-9_])"+NSRegularExpression.escapedPattern(for:expected)+"(?![A-Za-z0-9_])"
        if words.contains(where:{$0.value.filter{!$0.isWhitespace}.range(of:token,options:.regularExpression) != nil}) {return true}
        // Vision can split one ASCII token. Join only complete adjacent groups
        // on the same text row; unrelated regions/rows are never concatenated.
        let ascii=words.filter{$0.value.filter{!$0.isWhitespace}.range(of:"^[A-Z0-9]+$",options:.regularExpression) != nil}
            .sorted{$0.rect.midY==$1.rect.midY ? $0.rect.minX<$1.rect.minX:$0.rect.midY<$1.rect.midY}
        var groups=[[ScannerNavigationOCR.Text]]()
        for word in ascii {
            if let index=groups.firstIndex(where:{group in
                let anchor=group[0]
                return abs(anchor.rect.midY-word.rect.midY)<=min(anchor.rect.height,word.rect.height)*0.5
            }) {groups[index].append(word)} else {groups.append([word])}
        }
        for group in groups where group.count>1 {
            let ordered=group.sorted{$0.rect.minX<$1.rect.minX}
            let adjacent=zip(ordered,ordered.dropFirst()).allSatisfy {left,right in
                let gap=right.rect.minX-left.rect.maxX
                return gap >= -min(left.rect.width,right.rect.width)*0.2 && gap<=max(left.rect.height,right.rect.height)*1.5
            }
            if adjacent,ordered.map({$0.value.filter{!$0.isWhitespace}}).joined()==expected {return true}
        }
        return false
    }
    static func secondaryMatches(_ candidates:[String],expected:String)->Bool {
        candidates.contains{$0.filter{!$0.isWhitespace}==expected}
    }
}
