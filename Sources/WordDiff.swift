import Foundation

struct DiffSegment {
    enum Kind { case same, removed, added }
    let kind: Kind
    let text: String
}

/// Différence mot à mot, pour montrer ce qui a été corrigé (barré en rouge → en vert).
enum WordDiff {
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    static func segments(from original: String, to corrected: String) -> [DiffSegment] {
        let old = words(original), new = words(corrected)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        var out: [DiffSegment] = []
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                out.append(.init(kind: .removed, text: old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                out.append(.init(kind: .added, text: new[j])); j += 1
            } else if i < old.count, j < new.count {
                out.append(.init(kind: .same, text: new[j])); i += 1; j += 1
            } else { break }
        }
        return out
    }
}
