import SwiftUI
import AppKit
struct W: PreferenceKey { static var defaultValue: [String: CGFloat] = [:]; static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } } }
extension View { func measure(_ k: String) -> some View { background(GeometryReader { g in Color.clear.preference(key: W.self, value: [k: g.size.width]) }) } }
final class Box { var v: [String: CGFloat] = [:] }
func run(width: CGFloat, controlsInfinite: Bool) -> [String: CGFloat] {
  let box = Box()
  let crumb = "c11-messaging-primitive-design.md  ›  Delivery semantics  ›  Push delivery to waiting agents"
  let controls = Color.red.frame(width: 215, height: 26).fixedSize()
  let view = HStack(spacing: 8) {
    Color.blue.frame(width: 92, height: 26)
    Text(crumb).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).measure("crumbFrame")
    Text("42% · 9 min left").frame(width: 128, alignment: .trailing)
    Group { if controlsInfinite { controls.frame(maxWidth: .infinity, alignment: .trailing) } else { controls } }.measure("controlsFrame")
  }.padding(.horizontal, 8).frame(width: width, height: 35).onPreferenceChange(W.self) { box.v = $0 }
  let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: width, height: 35); host.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded()
  return box.v
}
for w: CGFloat in [800, 1120] { for inf in [true, false] { let r = run(width: w, controlsInfinite: inf); print("width=\(Int(w)) controlsMaxWidthInfinity=\(inf) crumbFrame=\(Int(r["crumbFrame"] ?? -1)) controlsFrame=\(Int(r["controlsFrame"] ?? -1))") } }
