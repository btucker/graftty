// Standalone native design studies. No production app code is imported or changed.
// swiftc -module-cache-path /private/tmp/context-design-module-cache render.swift -o /private/tmp/context-design-render
// /private/tmp/context-design-render <output-directory>
import AppKit
import SwiftUI

struct Palette {
    let name: String
    let bg: NSColor
    let fg: NSColor
    let dark: Bool
    func tone(_ fraction: CGFloat) -> Color {
        Color(nsColor: bg.blended(withFraction: fraction, of: fg)!)
    }
    var text: Color { Color(nsColor: fg) }
    var muted: Color { tone(0.68) }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    static let all = [
        Palette(name: "dark", bg: rgb(0.145, 0.161, 0.184), fg: rgb(0.92, 0.93, 0.94), dark: true),
        Palette(name: "light", bg: rgb(0.98, 0.97, 0.94), fg: rgb(0.23, 0.25, 0.27), dark: false),
        Palette(name: "warm", bg: rgb(0.16, 0.15, 0.13), fg: rgb(0.90, 0.86, 0.76), dark: true)
    ]
}

struct Study: View {
    let palette: Palette
    let option: Int
    var empty = false
    var mobile = false
    var raised: Color { palette.tone(palette.dark ? 0.095 : 0.045) }
    var base: Color { palette.tone(palette.dark ? 0.055 : 0.025) }
    var line: Color { palette.text.opacity(palette.dark ? 0.19 : 0.13) }
    var body: some View {
        HStack(spacing: 0) {
            if !mobile { terminal.frame(width: 90) }
            Group {
                if option == 1 {
                    VStack(spacing: 0) {
                        header
                        rule
                        brief.padding(24)
                        resize
                        history.padding(24).frame(maxHeight: .infinity, alignment: .top)
                    }.background(raised)
                } else if option == 2 {
                    VStack(spacing: 0) {
                        header
                        VStack(spacing: 0) {
                            brief.padding(20)
                            resize
                            history.padding(20).frame(maxHeight: .infinity, alignment: .top)
                        }
                        .background(raised, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(line, lineWidth: 0.5) }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }.background(base)
                } else {
                    VStack(spacing: 0) {
                        header.background(raised)
                        rule
                        brief.padding(24)
                            .frame(maxWidth: .infinity, minHeight: empty ? 240 : nil, alignment: .topLeading)
                            .background(raised)
                        resize.background(raised)
                        history.padding(24).frame(maxHeight: .infinity, alignment: .top)
                            .background(base)
                    }.background(base)
                }
            }
            .frame(width: 360)
            .overlay(alignment: .leading) { line.frame(width: 1) }
        }
        .foregroundStyle(palette.text)
        .font(.system(size: mobile ? 15 : 13))
        .frame(height: empty ? 480 : mobile ? 820 : 690)
        .background(palette.tone(0))
        .environment(\.colorScheme, palette.dark ? .dark : .light)
    }
    var rule: some View { line.frame(height: 1) }
    var resize: some View {
        ZStack {
            rule
            Capsule().fill(palette.tone(0.30)).frame(width: 25, height: mobile ? 4 : 3)
        }.frame(height: mobile ? 24 : 9)
    }
    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.right").foregroundStyle(palette.muted)
            Text("Context").fontWeight(.semibold)
            Spacer()
            Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(palette.muted)
        }.padding(.horizontal, 22).frame(height: 50)
    }
    var brief: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("graftty / context-sidebar-design")
                .font(.system(size: mobile ? 12 : 11)).foregroundStyle(palette.muted)
                .padding(.bottom, 8)
            Text("A distinct home for context")
                .font(.system(size: mobile ? 21 : 19, weight: .semibold)).padding(.bottom, 10)
            if empty {
                Text("No context yet").fontWeight(.semibold).padding(.top, 12)
                Text("Agent reports will build a current brief and decision history here.")
                    .foregroundStyle(palette.muted).lineSpacing(3).padding(.top, 8)
            } else {
                Text("Make the brief easy to find beside the terminal, in every Ghostty theme.")
                    .lineSpacing(3).padding(.bottom, 20)
                section("Where we are", "Comparing three ways to separate Context from the terminal.")
                section("What we’ve settled", "Follow the Ghostty palette. Align the brief to the top.")
                section("Up next", "Choose a treatment, then check it on Mac and mobile.", last: true)
                Text("Updated just now").font(.system(size: 10))
                    .foregroundStyle(palette.muted).padding(.top, 16)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
    func section(_ label: String, _ content: String, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: mobile ? 12 : 11, weight: .medium)).foregroundStyle(palette.muted)
            Text(content).lineSpacing(3)
        }.padding(.bottom, last ? 0 : 16)
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("How we got here").fontWeight(.semibold)
                Spacer()
                Text("Oldest first ↓").font(.system(size: 10)).foregroundStyle(palette.muted)
            }
            Text("Today").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
            event("You", time: "9:21 AM", content: "The context sidebar doesn’t look distinct from the terminal.", user: true)
            if !empty {
                event("Codex", time: "9:24 AM", content: "Three native treatments are ready to compare across dark and light palettes.", user: false)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    func event(_ sender: String, time: String, content: String, user: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 5) {
                Circle().fill(user ? Color.orange : palette.muted).frame(width: 6, height: 6)
                line.frame(width: 1)
            }.padding(.top, 4).frame(width: 6)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(sender).fontWeight(.semibold).foregroundStyle(user ? Color.orange : palette.text)
                    Spacer()
                    Text(time).foregroundStyle(palette.muted)
                }.font(.system(size: 11))
                Text(content).lineSpacing(3)
                if !user {
                    HStack { Text("Latest"); Spacer(); Text("Show more") }
                        .font(.system(size: 10)).foregroundStyle(palette.muted)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Terminal").font(.system(size: 11)).foregroundStyle(palette.muted)
                .frame(height: 50).padding(.horizontal, 12)
            rule
            Text("$ git diff\n\n struct\n   var body\n   VStack {\n     header\n   }\n\n$ swift test\n\n  Building\n  Sources\n  Context\n\n✓ Passed\n\n$ ")
                .font(.system(size: 11, design: .monospaced)).lineSpacing(8)
                .foregroundStyle(palette.text.opacity(0.65)).padding(.top, 20).padding(.leading, 12)
                .fixedSize(horizontal: true, vertical: true)
            Spacer()
        }.frame(maxHeight: .infinity).clipped().background(palette.tone(0))
    }
}

@MainActor func render(_ study: Study, name: String, output: URL) throws {
    let size = NSSize(width: study.mobile ? 360 : 450, height: study.empty ? 480 : study.mobile ? 820 : 690)
    let host = NSHostingView(rootView: study)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
    window.close()
    print("Rendered \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
}

try MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    for palette in Palette.all {
        for option in 1...3 {
            try render(Study(palette: palette, option: option, empty: palette.name == "light", mobile: palette.name == "warm"),
                name: "\(palette.name)-\(option)", output: destination)
        }
    }
}
