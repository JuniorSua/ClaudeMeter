// Generates AppIcon.icns: a coral squircle with three usage-meter bars.
// Run: swift scripts/make-icon.swift  (writes Sources/ClaudeMeter/Resources/AppIcon.icns)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Squircle plate with Apple's ~10% margin and Big Sur corner radius.
let inset: CGFloat = size * 0.098
let plate = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let platePath = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
platePath.addClip()

// Vertical warm-coral gradient (Claude-adjacent, not a trademark mark).
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.92, green: 0.55, blue: 0.40, alpha: 1),
    ending: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.21, alpha: 1)
)!
gradient.draw(in: plate, angle: -90)

// Three meter bars: white tracks with solid white fills at varying levels.
let barWidth = plate.width * 0.62
let barHeight = plate.height * 0.085
let barX = plate.midX - barWidth / 2
let gap = plate.height * 0.075
let fills: [CGFloat] = [0.80, 0.55, 0.30]
let totalHeight = 3 * barHeight + 2 * gap
var y = plate.midY + totalHeight / 2 - barHeight

for fill in fills {
    let track = NSRect(x: barX, y: y, width: barWidth, height: barHeight)
    NSColor(white: 1, alpha: 0.28).setFill()
    NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

    let filled = NSRect(x: barX, y: y, width: barWidth * fill, height: barHeight)
    NSColor(white: 1, alpha: 0.96).setFill()
    NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    y -= barHeight + gap
}

image.unlockFocus()

// Write master PNG, build the .iconset, then icns via iconutil.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "/tmp/ClaudeMeter.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = URL(fileURLWithPath: "/tmp/claudemeter-icon-1024.png")
try! png.write(to: master)

func run(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(args.joined(separator: " ")) failed")
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                   ("icon_512x512@2x", 1024)] {
    run(["/usr/bin/sips", "-z", "\(px)", "\(px)", master.path,
         "--out", iconset.appendingPathComponent("\(name).png").path])
}
run(["/usr/bin/iconutil", "-c", "icns", iconset.path,
     "-o", "Sources/ClaudeMeter/Resources/AppIcon.icns"])
print("Wrote Sources/ClaudeMeter/Resources/AppIcon.icns")
