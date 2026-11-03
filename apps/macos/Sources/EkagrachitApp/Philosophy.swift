import AppKit
import SwiftUI

/// The brand mark drawn in code: a ring around a single point.
enum BrandMark {
    /// 18 pt template image for the menu bar (adapts to light/dark bars).
    static func menuBarImage(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6.75, y: c.y - 6.75, width: 13.5, height: 13.5))
            ring.lineWidth = 1.5
            NSColor.black.setStroke()
            ring.stroke()
            let d: CGFloat = active ? 3.4 : 2.4
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ekagrachit"
        return image
    }
}

/// What the name means. Ekagrachit borrows its name and its idea from India's
/// contemplative traditions rooted in the Vedas; this is offered as a pointer,
/// in respect, not as instruction.
struct AboutView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("एकाग्रचित्त").font(.system(size: 28, weight: .semibold))
                        Text("ekāgra-citta · a mind gathered to one point").foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    term("eka", "one")
                    term("agra", "point, tip, the foremost")
                    term("citta", "mind, the field of consciousness")
                }

                section("The five states of mind") {
                    Text("In the Yoga tradition, Vyāsa's commentary on Patañjali's *Yoga Sūtras* describes five states the mind moves through:")
                    VStack(alignment: .leading, spacing: 6) {
                        state("kṣipta", "scattered — pulled in every direction")
                        state("mūḍha", "dull — heavy, unclear")
                        state("vikṣipta", "distracted — steady for a moment, then pulled away")
                        state("ekāgra", "one-pointed — gathered on a single object", highlight: true)
                        state("niruddha", "still — completely settled")
                    }
                    Text("Most knowledge work happens in *vikṣipta*: a mind that could hold a thought, if the next tab didn't take it. Ekagrachit can't make your mind one-pointed. It removes what keeps pulling it away, so *ekāgra* has room to happen.")
                }

                section("A lamp in a windless place") {
                    verse("yathā dīpo nivāta-stho neṅgate sopamā smṛtā",
                          "“As a lamp sheltered from the wind burns without a flicker, so burns the gathered mind.”",
                          "Bhagavad Gītā 6.19")
                    Text("That lamp is Ekagrachit's mark. The darkened screen is the windless place; your document is the flame.")
                }

                section("Returning is the practice") {
                    verse("yato yato niścarati manaś cañcalam asthiram / tatas tato niyamyaitad ātmany eva vaśaṁ nayet",
                          "“Wherever the restless mind wanders, draw it back from there, and let it rest within.”",
                          "Bhagavad Gītā 6.26")
                    Text("When you switch away and Ekagrachit brings you back, it isn't punishing a lapse. Wandering is what minds do; returning is the practice — what Patañjali calls *abhyāsa* (Yoga Sūtra 1.12–1.14).")
                }

                section("One place for the mind") {
                    verse("deśa-bandhaś cittasya dhāraṇā",
                          "“To hold the mind to a single place: this is concentration.”",
                          "Yoga Sūtra 3.1")
                    Text("One document, one window, one stretch of time: a place to bind attention to. The links you reach for are saved, so the thread isn't lost — only postponed.")
                }

                Text("These ideas come from India's contemplative traditions rooted in the Vedas. Ekagrachit borrows its name from them with respect; it is a tool, not a teacher.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Ekagrachit \(version)").foregroundStyle(.secondary)
                    Spacer()
                    Link("Website", destination: URL(string: "https://thunderboltsid.github.io/ekagrachit/")!)
                    Link("Privacy", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/blob/main/PRIVACY.md")!)
                }
                .font(.callout)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 540, height: 640)
        .textSelection(.enabled)
    }

    private func term(_ word: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(word).font(.headline)
            Text(meaning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func state(_ name: String, _ meaning: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(highlight ? Color(nsColor: Palette.lamp) : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
            Text(name).fontWeight(highlight ? .semibold : .regular).frame(width: 78, alignment: .leading)
            Text(meaning).foregroundStyle(highlight ? .primary : .secondary)
        }
    }

    private func verse(_ sanskrit: String, _ english: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sanskrit).italic().foregroundStyle(.secondary)
            Text(english)
            Text(source).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.lamp)).frame(width: 2) }
    }
}
