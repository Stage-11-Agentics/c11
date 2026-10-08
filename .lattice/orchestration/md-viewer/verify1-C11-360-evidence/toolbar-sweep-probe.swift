import SwiftUI
import AppKit
struct F: PreferenceKey { static var defaultValue: [String: CGRect] = [:]; static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } } }
extension View { func measure(_ k: String) -> some View { background(GeometryReader { g in Color.clear.preference(key: F.self, value: [k: g.frame(in: .named("bar"))]) }) } }
final class Box { var v: [String: CGRect] = [:] }
// Mirrors MarkdownReaderToolbar at 3aabd3b: outline 92/30 (label >= 700), breadcrumb maxWidth .infinity always, progress 128 (>= 430), controls fixedSize, no frame.
func run(_ width: CGFloat) -> [String: CGRect] {
  let box = Box()
  let crumb = width < 600 ? "Delivery semantics with a long heading" : "c11-messaging-primitive-design.md  ›  Delivery semantics  ›  Push delivery to waiting agents"
  let view = HStack(spacing: 8) {
    Color.blue.frame(width: width >= 700 ? 92 : 30, height: 26)
    Text(crumb).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(width < 600 ? .tail : .middle).frame(maxWidth: .infinity, alignment: .leading).measure("crumb")
    if width >= 430 { Text("42% · 9 min left").font(.system(size: 10, design: .monospaced)).lineLimit(1).frame(width: 128, alignment: .trailing).measure("progress") }
    HStack(spacing: 3) { Color.red.frame(width: 26, height: 26); Color.red.frame(width: 26, height: 26); Color.red.frame(width: 98, height: 26); Color.red.frame(width: 22, height: 22); Color.red.frame(width: 22, height: 22) }.fixedSize().measure("controls")
  }.padding(.horizontal, width < 360 ? 4 : 8).frame(width: width, height: 35).coordinateSpace(name: "bar").onPreferenceChange(F.self) { box.v = $0 }
  let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: width, height: 35); host.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
  return box.v
}
for w: CGFloat in [300, 360, 429, 430, 560, 599, 600, 700, 900, 1200] {
  let r = run(w); let c = r["controls"] ?? .zero
  print("width=\(Int(w)) controls.maxX=\(Int(c.maxX)) trailingGap=\(Int(w - c.maxX)) controlsWidth=\(Int(c.width)) crumbWidth=\(Int(r["crumb"]?.width ?? -1)) progressMaxX=\(r["progress"].map { String(Int($0.maxX)) } ?? "hidden") progress→controls gap=\(r["progress"].map { String(Int(c.minX - $0.maxX)) } ?? "-")")
}
